import Foundation
import Combine
import AVFoundation

public enum TelegramVoiceRecordingPhase: Equatable, Sendable {
    case idle, authorizing, recording, locked, finishing, failed
}

@MainActor public final class TelegramVoiceRecordingController: ObservableObject {
    @Published public private(set) var phase: TelegramVoiceRecordingPhase = .idle
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var level: Float = 0
    @Published public private(set) var error: String?
    @Published public private(set) var cancelConfirmationID: UUID?
    @Published public private(set) var canUseOneTime = false
    @Published public private(set) var isOneTime = false
    @Published public private(set) var selectedKind: TelegramRecordingKind = .voice
    public var previewSession: AVCaptureSession? { activeKind == .roundVideo ? roundVideoCapture?.previewSession : nil }
    public var isActive: Bool { phase != .idle && phase != .failed }
    var authorize: () async -> Bool = { false }
    var makeCapture: () throws -> any TelegramVoiceCapture = { throw CancellationError() }
    var eligibility: (TelegramUploadTarget) async -> TelegramVoiceEligibility = { _ in .unavailable }
    var oneTimeEligibility: (TelegramUploadTarget) async -> Bool = { _ in false }
    var isCurrent: (TelegramUploadTarget, UUID) -> Bool = { _,_ in false }
    var handoff: ([Int16], TelegramUploadTarget, UUID, Bool, Bool) async -> Bool = { _,_,_,_,_ in false }
    var didCancel: () -> Void = {}
    var authorizeRoundVideo: () async -> Bool = { false }
    var makeRoundVideoCapture: () throws -> any TelegramRoundVideoCapture = { throw CancellationError() }
    var roundVideoEligibility: (TelegramUploadTarget) async -> TelegramVoiceEligibility = { _ in .unavailable }
    var roundVideoOneTimeEligibility: (TelegramUploadTarget) async -> Bool = { _ in false }
    var roundVideoHandoff: (Data, TelegramUploadTarget, UUID, Bool, Bool) async -> Bool = { _, _, _, _, _ in false }
    private var sessionID = UUID()
    private var capture: (any TelegramVoiceCapture)?
    private var roundVideoCapture: (any TelegramRoundVideoCapture)?
    private var activeKind: TelegramRecordingKind?
    private var operation: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var target: TelegramUploadTarget?
    private var contextID: UUID?
    private var lockWhenReady = false
    public init() {}
    public func toggleKind() {
        guard phase == .idle || phase == .failed else { return }
        selectedKind = selectedKind == .voice ? .roundVideo : .voice
    }
    isolated deinit { operation?.cancel(); meter?.cancel(); capture?.cancel(); roundVideoCapture?.cancel() }

    func begin(target: TelegramUploadTarget, contextID: UUID) {
        guard !isActive, isCurrent(target, contextID) else { return }
        let kind = selectedKind
        cancel(); error = nil; self.target = target; self.contextID = contextID
        activeKind = kind
        let id = sessionID
        phase = .authorizing
        operation = Task { [weak self] in
            guard let self else { return }
            let first = await self.checkEligibility(target, kind: kind)
            guard self.current(id) else { return }
            guard first == .allowed else { self.fail(first.explanation(for: kind)); return }
            let permitted: Bool
            switch kind {
            case .voice: permitted = await self.authorize()
            case .roundVideo: permitted = await self.authorizeRoundVideo()
            }
            guard self.current(id) else { return }
            guard permitted else {
                self.fail(kind == .voice
                    ? "Разрешите доступ к микрофону в системных настройках, чтобы записать голосовое сообщение."
                    : "Разрешите доступ к камере и микрофону в системных настройках, чтобы записать видеосообщение.")
                return
            }
            let once: Bool
            switch kind {
            case .voice: once = await self.oneTimeEligibility(target)
            case .roundVideo: once = await self.roundVideoOneTimeEligibility(target)
            }
            guard self.current(id) else { return }
            self.canUseOneTime = once
            let fresh = await self.checkEligibility(target, kind: kind)
            guard self.current(id) else { return }
            guard fresh == .allowed else { self.fail(fresh.explanation(for: kind)); return }
            do {
                switch kind {
                case .voice:
                    let capture = try self.makeCapture()
                    try capture.start()
                    guard self.current(id) else { capture.cancel(); return }
                    self.capture = capture
                case .roundVideo:
                    let capture = try self.makeRoundVideoCapture()
                    // A release/navigation can cancel hardware while start is
                    // suspended. Metering begins only after async readiness.
                    self.roundVideoCapture = capture
                    try await capture.start()
                    guard self.current(id) else { capture.cancel(); return }
                }
                self.phase = self.lockWhenReady ? .locked : .recording
                self.updateMeter()
                self.meter = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self, self.current(id), self.phase == .recording || self.phase == .locked else { return }
                        self.updateMeter()
                        if self.duration >= self.maximumDuration || self.captureIsRecording != true {
                            self.finish(send: false); return
                        }
                    }
                }
            } catch {
                if self.current(id) {
                    self.fail(kind == .voice ? "Не удалось начать запись с микрофона." : "Не удалось начать запись с камеры и микрофона.")
                }
            }
        }
    }
    private func checkEligibility(_ target: TelegramUploadTarget, kind: TelegramRecordingKind) async -> TelegramVoiceEligibility {
        switch kind {
        case .voice: return await eligibility(target)
        case .roundVideo: return await roundVideoEligibility(target)
        }
    }
    private func current(_ id: UUID) -> Bool {
        guard sessionID == id, !Task.isCancelled, let target, let contextID else { return false }
        guard isCurrent(target, contextID) else { cancel(); return false }
        return true
    }
    private func updateMeter() {
        let rawDuration = activeKind == .roundVideo ? roundVideoCapture?.duration : capture?.duration
        let rawLevel = activeKind == .roundVideo ? roundVideoCapture?.level : capture?.level
        duration = max(0, min(maximumDuration, rawDuration ?? 0))
        level = max(0, min(1, rawLevel ?? 0))
    }
    private var maximumDuration: Double { activeKind == .roundVideo ? 60 : 600 }
    private var captureIsRecording: Bool? { activeKind == .roundVideo ? roundVideoCapture?.isRecording : capture?.isRecording }
    public func move(upward: Double) {
        if phase == .authorizing, upward > 100 { lockWhenReady = true }
        if phase == .recording, upward > 100 { phase = .locked }
    }
    public func release(inside: Bool) {
        if phase == .authorizing { if !lockWhenReady { cancel() } }
        else if phase == .recording { inside ? finish(send: true) : cancel() }
    }
    public func send() {
        guard phase == .recording || phase == .locked else { return }
        finish(send: true)
    }
    public func requestCancel() {
        if phase == .locked { cancelConfirmationID = sessionID }
        else { cancel() }
    }
    public func confirmCancel(id: UUID) {
        guard id == sessionID, cancelConfirmationID == id, phase == .locked else { return }
        cancel()
    }
    public func dismissCancelConfirmation() { cancelConfirmationID = nil }
    public func setOneTime(_ value: Bool) {
        guard phase == .locked, canUseOneTime else { return }
        isOneTime = value
    }
    public func cancel() {
        let active = isActive
        sessionID = UUID(); operation?.cancel(); operation = nil
        meter?.cancel(); meter = nil; capture?.cancel(); capture = nil
        roundVideoCapture?.cancel(); roundVideoCapture = nil; activeKind = nil
        target = nil; contextID = nil; cancelConfirmationID = nil
        lockWhenReady = false
        canUseOneTime = false; isOneTime = false
        duration = 0; level = 0; phase = .idle
        if active { didCancel() }
    }
    private func fail(_ message: String?) {
        cancel(); error = message; phase = .failed
    }
    private func finish(send: Bool) {
        guard let target, let contextID, let kind = activeKind else { cancel(); return }
        let voiceCapture = capture, roundCapture = roundVideoCapture
        guard kind == .voice ? voiceCapture != nil : roundCapture != nil else { cancel(); return }
        let id = sessionID
        guard current(id) else { return }
        let once = isOneTime
        meter?.cancel(); meter = nil; phase = .finishing; cancelConfirmationID = nil
        operation = Task { [weak self] in
            do {
                let admitted: Bool
                switch kind {
                case .voice:
                    guard let voiceCapture else { return }
                    let samples = try await voiceCapture.stop()
                    guard let self, self.current(id) else { return }
                    self.capture = nil
                    guard samples.count / 960 > 25, samples.count <= TelegramRecordedVoiceCodec.maximumSamples else { self.cancel(); return }
                    admitted = await self.handoff(samples, target, contextID, send, once)
                case .roundVideo:
                    guard let roundCapture else { return }
                    let bytes = try await roundCapture.stop()
                    guard let self, self.current(id) else { return }
                    self.roundVideoCapture = nil
                    // Strict encoded-byte/container/duration admission belongs
                    // to the durable round-video preparation boundary.
                    admitted = await self.roundVideoHandoff(bytes, target, contextID, send, once)
                }
                guard let self, self.current(id) else { return }
                if admitted { self.cancel() }
                else {
                    self.fail(kind == .voice ? "Не удалось передать запись в подготовку отправки." : "Не удалось передать видеосообщение в подготовку отправки.")
                }
            } catch {
                guard let self, self.current(id) else { return }
                self.fail(kind == .voice ? "Не удалось завершить запись голосового сообщения." : "Не удалось завершить запись видеосообщения.")
            }
        }
    }
}

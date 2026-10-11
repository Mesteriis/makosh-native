import Foundation
import Combine

public enum TelegramVoiceRecordingPhase: Equatable, Sendable {
    case idle, authorizing, recording, locked, finishing, failed
}

@MainActor public final class TelegramVoiceRecordingController: ObservableObject {
    @Published public private(set) var phase: TelegramVoiceRecordingPhase = .idle
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var level: Float = 0
    @Published public private(set) var error: String?
    @Published public private(set) var cancelConfirmationID: UUID?
    public var isActive: Bool { phase != .idle && phase != .failed }
    var authorize: () async -> Bool = { false }
    var makeCapture: () throws -> any TelegramVoiceCapture = { throw CancellationError() }
    var eligibility: (TelegramUploadTarget) async -> TelegramVoiceEligibility = { _ in .unavailable }
    var isCurrent: (TelegramUploadTarget, UUID) -> Bool = { _,_ in false }
    var handoff: ([Int16], TelegramUploadTarget, UUID, Bool) async -> Bool = { _,_,_,_ in false }
    var didCancel: () -> Void = {}
    private var sessionID = UUID()
    private var capture: (any TelegramVoiceCapture)?
    private var operation: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var target: TelegramUploadTarget?
    private var contextID: UUID?
    private var lockWhenReady = false
    public init() {}
    isolated deinit { operation?.cancel(); meter?.cancel(); capture?.cancel() }

    func begin(target: TelegramUploadTarget, contextID: UUID) {
        guard !isActive, isCurrent(target, contextID) else { return }
        cancel(); error = nil; self.target = target; self.contextID = contextID
        let id = sessionID
        phase = .authorizing
        operation = Task { [weak self] in
            guard let self else { return }
            let first = await self.eligibility(target)
            guard self.current(id) else { return }
            guard first == .allowed else { self.fail(first.explanation); return }
            let permitted = await self.authorize()
            guard self.current(id) else { return }
            guard permitted else { self.fail("Разрешите доступ к микрофону в системных настройках, чтобы записать голосовое сообщение."); return }
            let fresh = await self.eligibility(target)
            guard self.current(id) else { return }
            guard fresh == .allowed else { self.fail(fresh.explanation); return }
            do {
                let capture = try self.makeCapture()
                try capture.start()
                guard self.current(id) else { capture.cancel(); return }
                self.capture = capture; self.phase = self.lockWhenReady ? .locked : .recording
                self.updateMeter()
                self.meter = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self, self.current(id), self.phase == .recording || self.phase == .locked else { return }
                        self.updateMeter()
                        if self.duration >= 600 || self.capture?.isRecording != true {
                            self.finish(send: false); return
                        }
                    }
                }
            } catch { if self.current(id) { self.fail("Не удалось начать запись с микрофона.") } }
        }
    }
    private func current(_ id: UUID) -> Bool {
        guard sessionID == id, !Task.isCancelled, let target, let contextID else { return false }
        guard isCurrent(target, contextID) else { cancel(); return false }
        return true
    }
    private func updateMeter() {
        duration = max(0, min(600, capture?.duration ?? 0))
        level = max(0, min(1, capture?.level ?? 0))
    }
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
    public func cancel() {
        let active = isActive
        sessionID = UUID(); operation?.cancel(); operation = nil
        meter?.cancel(); meter = nil; capture?.cancel(); capture = nil
        target = nil; contextID = nil; cancelConfirmationID = nil
        lockWhenReady = false
        duration = 0; level = 0; phase = .idle
        if active { didCancel() }
    }
    private func fail(_ message: String?) {
        cancel(); error = message; phase = .failed
    }
    private func finish(send: Bool) {
        guard let capture, let target, let contextID else { cancel(); return }
        let id = sessionID
        guard current(id) else { return }
        meter?.cancel(); meter = nil; phase = .finishing; cancelConfirmationID = nil
        operation = Task { [weak self] in
            do {
                let samples = try await capture.stop()
                guard let self, self.current(id) else { return }
                self.capture = nil
                guard samples.count / 960 > 25, samples.count <= TelegramRecordedVoiceCodec.maximumSamples else { self.cancel(); return }
                let admitted = await self.handoff(samples, target, contextID, send)
                guard self.current(id) else { return }
                if admitted { self.cancel() }
                else { self.fail("Не удалось передать запись в подготовку отправки.") }
            } catch {
                guard let self, self.current(id) else { return }
                self.fail("Не удалось завершить запись голосового сообщения.")
            }
        }
    }
}

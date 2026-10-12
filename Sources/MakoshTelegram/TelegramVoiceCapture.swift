import Foundation
import AVFoundation

enum TelegramVoiceCapturePermission {
    static func requireAuthorized(_ status: AVAuthorizationStatus) throws {
        guard status == .authorized else { throw TelegramVoiceCaptureError.permissionDenied }
    }
}

@MainActor public protocol TelegramVoiceCapture: AnyObject {
    func start() throws
    func stop() async throws -> [Int16]
    func cancel()
    var duration: Double { get }
    var level: Float { get }
    var isRecording: Bool { get }
}

@MainActor public final class TelegramMicrophoneVoiceCapture: TelegramVoiceCapture {
    private var recorder: AVAudioRecorder?
    private var recorderDelegate: TelegramVoiceCaptureDelegate?
    private var stage: TelegramVoiceCapturePCM?
    private var finishing: Task<[Int16], Error>?
    private var used = false
    private var cancelled = false
    private var failed = false
    private var startedAt: TimeInterval?
    private var lastDuration: Double = 0

    /// Construction does not prepare a device or request permission. The caller owns the permission UI.
    public init() throws {}

    isolated deinit {
        recorder?.delegate = nil
        recorder?.stop()
        finishing?.cancel()
        stage?.discard()
    }

    public func start() throws {
        if cancelled { throw CancellationError() }
        guard !used else { throw TelegramVoiceCaptureError.invalidState }
        try TelegramVoiceCapturePermission.requireAuthorized(AVCaptureDevice.authorizationStatus(for: .audio))
        used = true
        do {
            let stage = try TelegramVoiceCapturePCM()
            self.stage = stage
            let recorder = try AVAudioRecorder(url: stage.url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            self.recorder = recorder
            let delegate = TelegramVoiceCaptureDelegate { [weak self] flag in self?.recordingFinished(flag) }
            recorderDelegate = delegate
            recorder.delegate = delegate
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else { throw TelegramVoiceCaptureError.unavailable }
            try stage.secureForRecording()
            guard recorder.record(forDuration: 600) else { throw TelegramVoiceCaptureError.unavailable }
            startedAt = ProcessInfo.processInfo.systemUptime
        } catch {
            recorder?.delegate = nil; recorder?.stop(); recorder = nil; recorderDelegate = nil
            stage?.discard(); stage = nil
            throw TelegramVoiceCaptureError.unavailable
        }
    }

    public func stop() async throws -> [Int16] {
        if cancelled { throw CancellationError() }
        guard finishing == nil, let recorder, let stage else { throw TelegramVoiceCaptureError.invalidState }
        _ = duration
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        recorderDelegate = nil
        do {
            guard !failed else { throw TelegramVoiceCaptureError.invalidRecording }
            try stage.seal()
            let worker = Task { try await stage.consume() }
            finishing = worker
            let pcm = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            if cancelled { throw CancellationError() }
            lastDuration = Double(pcm.count) / 48_000
            finishing = nil; self.stage = nil
            return pcm
        } catch {
            stage.discard(); self.stage = nil; finishing = nil
            if cancelled || Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? TelegramVoiceCaptureError { throw error }
            throw TelegramVoiceCaptureError.invalidRecording
        }
    }

    public func cancel() {
        cancelled = true
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; recorderDelegate = nil
        finishing?.cancel()
        stage?.discard(); stage = nil
    }

    public var duration: Double {
        if let recorder, recorder.isRecording {
            let current = recorder.currentTime
            if current.isFinite { lastDuration = max(lastDuration, min(600, max(0, current))) }
        }
        return lastDuration
    }

    public var level: Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let value = recorder.averagePower(forChannel: 0)
        return value.isFinite ? min(1, max(0, pow(10, value / 20))) : 0
    }

    public var isRecording: Bool { recorder?.isRecording ?? false }

    private func recordingFinished(_ flag: Bool) {
        guard recorder != nil else { return }
        failed = !flag
        if flag, let start = startedAt {
            lastDuration = max(lastDuration, min(600, ProcessInfo.processInfo.systemUptime - start))
        }
    }
}

@MainActor private final class TelegramVoiceCaptureDelegate: NSObject, AVAudioRecorderDelegate {
    private let finished: @MainActor @Sendable (Bool) -> Void
    init(finished: @escaping @MainActor @Sendable (Bool) -> Void) { self.finished = finished }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finished(flag) }
    }
    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.finished(false) }
    }
}

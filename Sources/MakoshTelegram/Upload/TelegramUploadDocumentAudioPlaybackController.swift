import Foundation
import Combine
import AVFoundation
import Darwin

@MainActor public final class TelegramUploadDocumentAudioPlaybackController: ObservableObject {
    @Published public private(set) var phase: TelegramPlaybackPhase = .idle
    @Published public private(set) var error: String?
    private(set) var player: AVPlayer?
    private var engine: TelegramNativePlaybackEngine?
    private var copy: TelegramPlaybackFile?
    private var generation: UUID?
    private var deadline: Task<Void, Never>?
    private var preparation: Task<TelegramPlaybackFile, Error>?
    private let prepareFile: @MainActor (TelegramUploadFile) async throws -> TelegramPlaybackFile
    public init() { prepareFile = Self.prepare }
    init(prepare: @escaping @MainActor (TelegramUploadFile) async throws -> TelegramPlaybackFile) { prepareFile = prepare }
    public var canControl: Bool { [.ready, .playing, .paused, .buffering, .ended].contains(phase) }

    /// Prepare silently after an explicit UI request. The decoder owns a separate local-only copy.
    public func load(_ file: TelegramUploadFile) async {
        guard !Task.isCancelled else { return }
        stop()
        let id = UUID(); generation = id; phase = .loading
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.generation == id else { return }
            self?.expireLoading()
        }
        var prepared: TelegramPlaybackFile?
        defer {
            if let prepared, copy?.id != prepared.id { try? TelegramPlaybackFileIO.discard(prepared) }
        }
        do {
            let prepare = prepareFile
            let worker = Task { try await prepare(file) }
            preparation = worker
            prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            if generation == id { preparation = nil }
            try Task.checkCancellation()
            guard generation == id, let prepared else { throw CancellationError() }
            copy = prepared
            let engine = TelegramNativePlaybackEngine(keepsItemAtEnd: true)
            self.engine = engine
            _ = try await engine.load(file: prepared.url, kind: .audio) { [weak self] event in
                self?.receive(event, id: id)
            }
            try Task.checkCancellation()
            guard generation == id, let player = engine.player else { throw CancellationError() }
            self.player = player; phase = .ready; deadline?.cancel(); deadline = nil
        } catch {
            guard generation == id else { return }
            let cancelled = Task.isCancelled || error is CancellationError
            stop()
            if !cancelled { phase = .failed; self.error = "Не удалось воспроизвести предпросмотр аудио." }
        }
    }

    private static func prepare(_ file: TelegramUploadFile) async throws -> TelegramPlaybackFile {
        try Task.checkCancellation()
        guard file.mode == .file, case .audio? = file.metadata else { throw TelegramUploadFileError.invalidAudio }
        try TelegramUploadFileIO.validateOwnedStage(file)
        let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_size == file.size else { throw TelegramUploadFileError.unavailable }
        try await TelegramUploadFileIO.verifyMetadata(file)
        let result = try await TelegramPlaybackFileIO.prepare(source: file.url, expectedSize: file.size)
        var complete = false
        defer { if !complete { try? TelegramPlaybackFileIO.discard(result) } }
        try Task.checkCancellation()
        try TelegramUploadVideoIO.validateSnapshot(file, fd: fd, original: original)
        complete = true
        return result
    }

    public func toggle() {
        guard generation != nil, canControl, let engine else { return }
        if phase == .playing || phase == .buffering { engine.pause(); phase = .paused }
        else {
            if phase == .ended { engine.seek(seconds: 0) }
            engine.play(rate: 1); phase = .playing
        }
    }

    private func receive(_ event: TelegramPlaybackEvent, id: UUID) {
        guard generation == id else { return }
        switch event {
        case .ended: phase = .ended
        case .failed: stop(); phase = .failed; error = "Воспроизведение предпросмотра прервано."
        case .transport(.waiting): if phase == .playing { phase = .buffering }
        case .transport(.playing): if phase == .buffering { phase = .playing }
        case .transport, .position: break
        }
    }

    /// The real deadline and deterministic cancellation tests share this terminal path.
    func expireLoading() {
        guard phase == .loading else { return }
        stop(); phase = .timedOut; error = "Не удалось открыть аудио за 30 секунд."
    }

    public func stop() {
        generation = nil; deadline?.cancel(); deadline = nil
        preparation?.cancel(); preparation = nil
        engine?.stop(); engine = nil; player = nil; phase = .idle; error = nil
        if let copy {
            do { try TelegramPlaybackFileIO.discard(copy) }
            catch { self.error = "Не удалось удалить временную копию воспроизведения." }
        }
        copy = nil
    }
    isolated deinit {
        preparation?.cancel(); deadline?.cancel(); engine?.stop()
        if let copy { try? TelegramPlaybackFileIO.discard(copy) }
    }
}

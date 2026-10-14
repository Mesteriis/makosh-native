import Foundation
import Combine
import AVFoundation

public enum TelegramPlaybackPhase: Equatable, Sendable {
    case idle, preparing, loading, ready, playing, paused, buffering, ended, failed, timedOut
}

/// One explicitly opened local resource. Pausing retains the cache borrow;
/// stopping detaches the decoder before releasing either owned file.
@MainActor
public final class TelegramPlaybackController: ObservableObject {
    @MainActor private final class Lifetime {
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if finished { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func finish() {
            guard !finished else { return }
            finished = true
            let previous = continuation; continuation = nil
            previous?.resume()
        }
    }

    @Published public private(set) var phase: TelegramPlaybackPhase = .idle
    @Published public private(set) var attachment: TelegramAttachment?
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var hasVideo = false
    @Published public private(set) var error: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var rate: Float = 1
    public var isActive: Bool { token != nil }
    public var canControl: Bool { [.ready, .playing, .paused, .buffering].contains(phase) }

    private let makeEngine: @MainActor () -> any TelegramPlaybackEngine
    private var engine: (any TelegramPlaybackEngine)?
    private var token: UUID?
    private var lifetime: Lifetime?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    public init() { makeEngine = { TelegramNativePlaybackEngine() } }
    init(makeEngine: @escaping @MainActor () -> any TelegramPlaybackEngine) { self.makeEngine = makeEngine }

    public func open(attachment: TelegramAttachment, media: TelegramMediaController) {
        let key = TelegramMediaKey(attachmentID: attachment.id, purpose: .full)
        guard !isBusy, !isActive, attachment.playback != nil, attachment.canDownload,
              [.ready,.capturing].contains(media.phase(for:key)) else { return }
        let id = UUID(), lifetime = Lifetime(), engine = makeEngine()
        token = id; self.lifetime = lifetime; self.engine = engine
        self.attachment = attachment; position = 0; duration = 0; hasVideo = false
        error = nil; phase = .preparing; isBusy = true
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.token == id else { return }
            self?.expireLoading()
        }
        worker = Task { [weak self] in
            guard let self else { return }
            await run(id: id, attachment: attachment, media: media, key: key,
                      engine: engine, lifetime: lifetime)
        }
    }

    private func run(id: UUID, attachment: TelegramAttachment, media: TelegramMediaController,
                     key: TelegramMediaKey, engine: any TelegramPlaybackEngine, lifetime: Lifetime) async {
        var file: TelegramPlaybackFile?
        defer {
            // Stop is idempotent, and must precede unlinking a decoder's input.
            engine.stop()
            if let file {
                do { try TelegramPlaybackFileIO.discard(file) }
                catch { self.error = "Не удалось удалить временную копию воспроизведения." }
            }
            worker = nil; isBusy = false
        }
        do {
            let available = try await media.withDownloadedFile(for: key) { url, size in
                defer { engine.stop() }
                try Task.checkCancellation()
                file = try await TelegramPlaybackFileIO.prepare(source: url, expectedSize: size)
                try Task.checkCancellation()
                guard self.token == id, let file, let kind = attachment.playback else { throw CancellationError() }
                self.phase = .loading
                let info = try await engine.load(file: file.url, kind: kind) { [weak self] event in
                    self?.receive(event, id: id)
                }
                try Task.checkCancellation()
                guard self.token == id else { throw CancellationError() }
                self.duration = info.duration; self.hasVideo = info.hasVideo
                self.player = engine.player; self.phase = .ready
                self.deadline?.cancel(); self.deadline = nil
                await lifetime.wait()
                // The source borrow ends only after the native player detaches.
                engine.stop()
            }
            if !available, token == id {
                terminate(phase: .failed, error: TelegramPlaybackFileError.unavailable.localizedDescription)
            }
        } catch is CancellationError {
            if token == id { terminate(phase: .idle, clearAttachment: true) }
        } catch {
            guard token == id else { return }
            let safe = (error as? TelegramPlaybackFileError)?.localizedDescription
                ?? "Не удалось воспроизвести файл. Его можно сохранить и открыть другим приложением."
            terminate(phase: .failed, error: safe)
        }
    }

    public func togglePlayback() {
        guard canControl else { return }
        if phase == .playing || phase == .buffering { engine?.pause() }
        else { engine?.play(rate: rate) }
    }

    public func seek(seconds: Double) {
        guard canControl, seconds.isFinite else { return }
        engine?.seek(seconds: min(duration, max(0, seconds)))
    }

    public func setRate(_ value: Float) {
        guard [Float(0.5), 1, 1.5, 2].contains(value) else { return }
        rate = value
        if phase == .playing { engine?.play(rate: value) }
    }

    public func stop() { terminate(phase: .idle, clearAttachment: true) }

    public func retain(attachments: [TelegramAttachment]) {
        guard let attachment else { return }
        if !attachments.contains(attachment) { stop() }
    }

    /// The real deadline and deterministic tests use the same terminal path.
    func expireLoading() {
        guard isActive, phase == .preparing || phase == .loading else { return }
        terminate(phase: .timedOut, error: "Файл не подготовлен за 30 секунд. Можно закрыть проигрыватель и повторить попытку.")
    }

    private func receive(_ event: TelegramPlaybackEvent, id: UUID) {
        guard token == id else { return }
        switch event {
        case .transport(let state):
            guard canControl else { return }
            switch state {
            case .playing: phase = .playing
            case .paused: phase = .paused
            case .waiting: phase = .buffering
            }
        case .position(let value):
            if canControl, value.isFinite { position = min(duration, max(0, value)) }
        case .ended:
            position = duration
            terminate(phase: .ended)
        case .failed:
            terminate(phase: .failed, error: "Воспроизведение прервано. Файл можно сохранить для другого проигрывателя.")
        }
    }

    private func terminate(phase: TelegramPlaybackPhase, error: String? = nil, clearAttachment: Bool = false) {
        token = nil
        deadline?.cancel(); deadline = nil
        worker?.cancel()
        engine?.stop(); engine = nil; player = nil
        lifetime?.finish(); lifetime = nil
        self.phase = phase; self.error = error
        if clearAttachment { attachment = nil; position = 0; duration = 0; hasVideo = false }
    }

    isolated deinit {
        worker?.cancel(); deadline?.cancel(); engine?.stop(); lifetime?.finish()
    }
}

import Foundation
import Combine
import AVFoundation
import UniformTypeIdentifiers
import Darwin

@MainActor
public final class TelegramUploadVideoPlaybackController: ObservableObject {
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var error: String?
    private var engine: TelegramNativePlaybackEngine?
    private var generation: UUID?
    private var visible = false
    private var loopSeekID: UUID?
    private var deadline: Task<Void, Never>?
    private let seekToStart: @MainActor (AVPlayer, @escaping @MainActor (Bool) -> Void) -> Void

    init(seekToStart: @escaping @MainActor (AVPlayer, @escaping @MainActor (Bool) -> Void) -> Void = { player, completion in
        player.seek(to: .zero) { finished in
            Task { @MainActor in completion(finished) }
        }
    }) {
        self.seekToStart = seekToStart
    }

    /// Borrows the immutable owned stage. The upload owner stops this decoder
    /// before submitting or releasing it; this controller never discards bytes.
    func load(_ file: TelegramUploadFile) async {
        await load(file, kind: .video)
    }

    /// Explicit recorded-round preview revalidates the frozen intent and actual bytes.
    func loadRoundVideo(_ file: TelegramUploadFile) async {
        await load(file, kind: .roundVideo)
    }

    private func load(_ file: TelegramUploadFile, kind: TelegramPlaybackKind) async {
        guard !Task.isCancelled else { return }
        stop()
        let id = UUID(); generation = id
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.generation == id else { return }
            self?.stop(); self?.error = "Не удалось открыть видео за 30 секунд."
        }
        do {
            try Task.checkCancellation()
            try TelegramUploadFileIO.validateOwnedStage(file)
            guard kind == .video || kind == .roundVideo,
                  kind == .roundVideo || file.metadata?.roundVideo == nil,
                  file.mode == .video, let video = file.video,
                  video.isValid(name: file.name, size: file.size),
                  file.pixelWidth == video.width, file.pixelHeight == video.height else { throw TelegramUploadFileError.invalidVideo }
            let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
            defer { Darwin.close(fd) }
            var original = stat()
            guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
                  original.st_size == file.size else { throw TelegramUploadFileError.unavailable }
            if kind == .roundVideo {
                _ = try await TelegramRecordedRoundVideoIO.inspect(file)
            } else {
                let info = try await TelegramUploadVideoIO.inspect(file)
                guard info.width == video.width, info.height == video.height,
                      info.duration == video.duration, info.hasAudio == video.hasAudio else { throw TelegramUploadFileError.invalidVideo }
            }
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            let mime = kind == .roundVideo ? "video/mp4"
                : UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType
            let engine = TelegramNativePlaybackEngine(mimeType: mime, keepsItemAtEnd: true)
            self.engine = engine
            _ = try await engine.load(file: file.url, kind: kind) { [weak self] event in
                self?.receive(event, id: id)
            }
            try Task.checkCancellation()
            guard generation == id, let player = engine.player else { throw CancellationError() }
            try TelegramUploadVideoIO.validateSnapshot(file, fd: fd, original: original)
            player.isMuted = true; engine.setVolume(0)
            deadline?.cancel(); deadline = nil
            self.player = player
        } catch {
            guard generation == id else { return }
            let cancelled = Task.isCancelled || error is CancellationError
            stop()
            if !cancelled { self.error = "Не удалось воспроизвести предпросмотр видео." }
        }
    }

    /// A dismantled/replaced native view cannot change the current player's state.
    public func setVisible(_ visible: Bool, player: AVPlayer) {
        guard self.player === player, generation != nil else { return }
        self.visible = visible
        if visible && loopSeekID == nil { engine?.play(rate: 1) } else { engine?.pause() }
    }

    private func receive(_ event: TelegramPlaybackEvent, id: UUID) {
        guard generation == id else { return }
        switch event {
        case .ended:
            if let player { repeatIfVisible(player: player) }
        case .failed:
            stop(); error = "Воспроизведение предпросмотра прервано."
        case .transport, .position: break
        }
    }

    func repeatIfVisible(player: AVPlayer) {
        guard self.player === player, let generation else { return }
        engine?.pause()
        guard visible, loopSeekID == nil else { return }
        let seekID = UUID(); loopSeekID = seekID
        seekToStart(player) { [weak self, weak player] finished in
            guard let self, let player, self.generation == generation,
                  self.player === player, self.loopSeekID == seekID else { return }
            self.loopSeekID = nil
            if finished && self.visible { self.engine?.play(rate: 1) }
            else { self.engine?.pause() }
        }
    }

    public func stop() {
        generation = nil; loopSeekID = nil; deadline?.cancel(); deadline = nil
        engine?.stop(); engine = nil; player = nil; visible = false; error = nil
    }
    isolated deinit { deadline?.cancel(); engine?.stop() }
}

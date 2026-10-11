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
    private var deadline: Task<Void, Never>?

    /// Borrows the immutable owned stage. The upload owner stops this decoder
    /// before submitting or releasing it; this controller never discards bytes.
    func load(_ file: TelegramUploadFile) async {
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
            guard file.mode == .video, let video = file.video,
                  video.isValid(name: file.name, size: file.size),
                  file.pixelWidth == video.width, file.pixelHeight == video.height else { throw TelegramUploadFileError.invalidVideo }
            let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
            defer { Darwin.close(fd) }
            var original = stat()
            guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
                  original.st_size == file.size else { throw TelegramUploadFileError.unavailable }
            let info = try await TelegramUploadVideoIO.inspect(file)
            guard info.width == video.width, info.height == video.height,
                  info.duration == video.duration, info.hasAudio == video.hasAudio,
                  generation == id else { throw TelegramUploadFileError.invalidVideo }
            let mime = UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType
            let engine = TelegramNativePlaybackEngine(mimeType: mime, keepsItemAtEnd: true)
            self.engine = engine
            _ = try await engine.load(file: file.url, kind: .video) { [weak self] event in
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
        if visible { engine?.play(rate: 1) } else { engine?.pause() }
    }

    private func receive(_ event: TelegramPlaybackEvent, id: UUID) {
        guard generation == id else { return }
        switch event {
        case .ended:
            engine?.seek(seconds: 0)
            if visible { engine?.play(rate: 1) }
        case .failed:
            stop(); error = "Воспроизведение предпросмотра прервано."
        case .transport, .position: break
        }
    }

    public func stop() {
        generation = nil; deadline?.cancel(); deadline = nil
        engine?.stop(); engine = nil; player = nil; visible = false; error = nil
    }
    isolated deinit { deadline?.cancel(); engine?.stop() }
}

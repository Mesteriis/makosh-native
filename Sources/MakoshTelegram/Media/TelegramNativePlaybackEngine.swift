import Foundation
import AVFoundation
import Darwin

enum TelegramNativePlaybackError: LocalizedError, Equatable {
    case unavailable
    var errorDescription: String? { "Не удалось воспроизвести этот файл." }
}

@MainActor
final class TelegramNativePlaybackEngine: TelegramPlaybackEngine {
    private let mimeType: String?
    private let keepsItemAtEnd: Bool
    private let muted: Bool, maximumDuration: Double, maximumVideoDimension: CGFloat
    private(set) var player: AVPlayer?
    private var asset: AVURLAsset?
    private var generation: UUID?
    private var transportObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?

    init(mimeType: String? = nil, keepsItemAtEnd: Bool = false,muted:Bool = false,maximumDuration:Double = 7*24*60*60,maximumVideoDimension:CGFloat = 8192) {
        self.mimeType = mimeType; self.keepsItemAtEnd = keepsItemAtEnd; self.muted = muted
        self.maximumDuration = maximumDuration; self.maximumVideoDimension = maximumVideoDimension
    }

    isolated deinit { cleanUp() }

    static func restrictedAsset(file: URL, mimeType: String? = nil) -> AVURLAsset {
        var options: [String: Any] = [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetShouldSupportAliasDataReferencesKey: false
        ]
        if let mimeType { options[AVURLAssetOverrideMIMETypeKey] = mimeType }
        return AVURLAsset(url: file, options: options)
    }

    func load(file: URL, kind: TelegramPlaybackKind,
              receive: @escaping @MainActor (TelegramPlaybackEvent) -> Void) async throws -> TelegramPlaybackInfo {
        stop()
        try Task.checkCancellation()
        guard file.isFileURL, !file.path.utf8.contains(0) else { throw TelegramNativePlaybackError.unavailable }
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0 else { throw TelegramNativePlaybackError.unavailable }
        let token = UUID()
        generation = token
        let asset = Self.restrictedAsset(file: file, mimeType: mimeType)
        self.asset = asset
        do {
            return try await withTaskCancellationHandler {
                let playable = try await asset.load(.isPlayable)
                try validate(token)
                let duration = try await asset.load(.duration).seconds
                try validate(token)
                guard playable, duration.isFinite, duration > 0, duration <= maximumDuration else {
                    throw TelegramNativePlaybackError.unavailable
                }
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                try validate(token)
                let needsVideo = kind == .video || kind == .roundVideo
                if needsVideo {
                    guard !videoTracks.isEmpty else { throw TelegramNativePlaybackError.unavailable }
                    for track in videoTracks {
                        let size = try await track.load(.naturalSize)
                        try validate(token)
                        let width = abs(size.width), height = abs(size.height)
                        guard width.isFinite, height.isFinite, width > 0, height > 0,
                              width <= maximumVideoDimension, height <= maximumVideoDimension, width * height <= 40_000_000 else {
                            throw TelegramNativePlaybackError.unavailable
                        }
                    }
                } else {
                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                    try validate(token)
                    guard !audioTracks.isEmpty, videoTracks.isEmpty else { throw TelegramNativePlaybackError.unavailable }
                }
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                player.isMuted = muted
                player.allowsExternalPlayback = false
                self.player = player
                // No autoplay. Observe readiness with cancellable polling; controller owns the loading deadline.
                while item.status == .unknown {
                    try await Task.sleep(for: .milliseconds(20))
                    try validate(token)
                }
                guard item.status == .readyToPlay else { throw TelegramNativePlaybackError.unavailable }
                try validate(token)
                installObservers(player: player, item: item, token: token, receive: receive)
                return TelegramPlaybackInfo(duration: duration, hasVideo: needsVideo)
            } onCancel: {
                asset.cancelLoading()
                Task { @MainActor [weak self] in
                    guard self?.generation == token else { return }
                    self?.stop()
                }
            }
        } catch {
            if generation == token { stop() }
            if error is CancellationError { throw CancellationError() }
            throw TelegramNativePlaybackError.unavailable
        }
    }

    private func validate(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func installObservers(player: AVPlayer, item: AVPlayerItem, token: UUID,
                                  receive: @escaping @MainActor (TelegramPlaybackEvent) -> Void) {
        transportObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard self?.generation == token else { return }
                receive(.transport(status == .playing ? .playing : status == .paused ? .paused : .waiting))
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard self?.generation == token else { return }
                self?.stop()
                receive(.failed)
            }
        }
        for (name, event) in [(AVPlayerItem.didPlayToEndTimeNotification, TelegramPlaybackEvent.ended),
                              (AVPlayerItem.failedToPlayToEndTimeNotification, TelegramPlaybackEvent.failed)] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard self?.generation == token else { return }
                    if name != AVPlayerItem.didPlayToEndTimeNotification || self?.keepsItemAtEnd != true { self?.stop() }
                    receive(event)
                }
            })
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard self?.generation == token, seconds.isFinite else { return }
                receive(.position(seconds))
            }
        }
    }

    func play(rate: Float) {
        guard rate.isFinite else { return }
        player?.rate = min(2, max(0.5, rate))
    }
    func pause() { player?.pause() }
    func seek(seconds: Double) {
        guard seconds.isFinite, let player, let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        player.seek(to: CMTime(seconds: min(duration, max(0, seconds)), preferredTimescale: 600))
    }
    func setVolume(_ volume: Float) {
        guard volume.isFinite else { return }
        player?.volume = min(1, max(0, volume))
    }
    func stop() { generation = nil; cleanUp() }
    private func cleanUp() {
        asset?.cancelLoading()
        player?.pause()
        transportObservation?.invalidate(); transportObservation = nil
        statusObservation?.invalidate(); statusObservation = nil
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        notifications.removeAll()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        asset = nil
    }
}

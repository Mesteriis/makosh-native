import SwiftUI
import AVKit
import MakoshTelegram

/// The reference's preparation preview loops silently only in its visible key
/// window. AVPlayerView supplies the native video surface without extra chrome.
struct TelegramUploadVideoPlayerView: View {
    @ObservedObject var playback: TelegramUploadVideoPlaybackController
    var body: some View {
        if let player = playback.player {
            NativeVideoSurface(player: player) { visible in
                playback.setVisible(visible, player: player)
            }
            .frame(height: 240).frame(maxWidth: .infinity)
            .accessibilityLabel("Видеопредпросмотр без звука")
            .accessibilityIdentifier("telegram.upload.videoPlayback")
        } else if let error = playback.error {
            Label(error, systemImage: "video.slash").font(.caption)
                .padding(8).background(.regularMaterial)
                .accessibilityIdentifier("telegram.upload.videoPlaybackError")
        }
    }
}

/// Finished round recordings keep the capture circle and omit its progress ring.
struct TelegramRoundVideoPlayerView: View {
    @ObservedObject var playback: TelegramUploadVideoPlaybackController
    var body: some View {
        ZStack {
            Circle().fill(.black)
            if let player = playback.player {
                NativeVideoSurface(player: player, roundVideo: true) { visible in
                    playback.setVisible(visible, player: player)
                }
            } else if let error = playback.error {
                Label(error, systemImage: "video.slash").font(.caption)
                    .foregroundStyle(.white).multilineTextAlignment(.center).padding(24)
                    .accessibilityIdentifier("telegram.roundVideo.videoPlaybackError")
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: 264, height: 264).clipShape(Circle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Предпросмотр подготовленного круглого видео")
        .accessibilityIdentifier("telegram.roundVideo.preparedPreview")
    }
}

private struct NativeVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var roundVideo = false
    let visibilityChanged: @MainActor (Bool) -> Void
    func makeNSView(context: Context) -> UploadVideoSurface {
        let view = UploadVideoSurface()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.roundVideo = roundVideo
        view.videoGravity = roundVideo ? .resizeAspectFill : .resizeAspect
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Видеопредпросмотр без звука")
        view.setAccessibilityIdentifier(roundVideo ? "telegram.roundVideo.videoPlayback" : "telegram.upload.videoPlayback")
        view.player = player; view.visibilityChanged = visibilityChanged
        return view
    }
    func updateNSView(_ view: UploadVideoSurface, context: Context) {
        view.visibilityChanged = visibilityChanged
        if view.player !== player { view.player = player }
        view.updateVisibility()
    }
    static func dismantleNSView(_ view: UploadVideoSurface, coordinator: ()) { view.tearDown() }
}

private final class UploadVideoSurface: AVPlayerView {
    var roundVideo = false {
        didSet { if roundVideo { wantsLayer = true }; needsLayout = true }
    }
    var visibilityChanged: (@MainActor (Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    override func layout() {
        super.layout()
        if roundVideo {
            layer?.masksToBounds = true
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.updateVisibility() }
                })
            }
        }
        updateVisibility()
    }
    func updateVisibility() {
        visibilityChanged?(window?.isKeyWindow == true && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor)
    }
    func tearDown() {
        visibilityChanged?(false); visibilityChanged = nil
        removeObservers(); player = nil
    }
    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    isolated deinit { removeObservers() }
}

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

private struct NativeVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let visibilityChanged: @MainActor (Bool) -> Void
    func makeNSView(context: Context) -> UploadVideoSurface {
        let view = UploadVideoSurface()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Видеопредпросмотр без звука")
        view.setAccessibilityIdentifier("telegram.upload.videoPlayback")
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
    var visibilityChanged: (@MainActor (Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
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

import SwiftUI
import AVKit
import MakoshTelegram

struct TelegramCallAvatar: View {
    let title: String
    let peerID: Int64
    @ObservedObject var store: TelegramAvatarStore
    let enabled: Bool
    @StateObject private var playback = TelegramAvatarVideoPlayback()
    private struct Request: Equatable { let peerID:Int64; let context:UUID; let enabled:Bool }
    private var request: Request { .init(peerID:peerID,context:store.contextID,enabled:enabled) }
    var body: some View {
        ZStack {
            TelegramChatAvatar(title:title,peerID:peerID,store:store,size:110)
            if enabled,let player = playback.player { CallAvatarVideoSurface(player:player).accessibilityIdentifier("telegram.call.videoAvatar") }
        }.frame(width:110,height:110).clipShape(Circle()).accessibilityHidden(true)
            .help(playback.error ?? "Видеоаватар без звука")
            .task(id:request) {
                playback.stop()
                if enabled { playback.open(store:store,peerID:peerID) }
            }.onDisappear { playback.stop() }
    }
}
private struct CallAvatarVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context:Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .none; view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspectFill; view.player = player; return view
    }
    func updateNSView(_ view:AVPlayerView,context:Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view:AVPlayerView,coordinator:()) { view.player = nil }
}

struct TelegramCallDecorationView: View {
    let animate: Bool
    let connected: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval:1/30,paused:!animate)) { timeline in
            let time = animate ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:1000) : 0
            Canvas { context,size in
                for layer in 0..<3 {
                    var path = Path()
                    for step in 0...64 {
                        let angle = Double(step)/64*2*Double.pi
                        let radius = TelegramCallDecoration.radius(angle:angle,phase:time*0.7+Double(layer)*2,base:64+Double(layer)*2)
                        let point = CGPoint(x:size.width/2+cos(angle)*radius,y:size.height/2+sin(angle)*radius)
                        if step == 0 { path.move(to:point) } else { path.addLine(to:point) }
                    }
                    path.closeSubpath()
                    context.fill(path,with:.color((connected ? Color.green : Color.blue).opacity(0.1+Double(layer)*0.04)))
                }
            }
        }.frame(width:170,height:170).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// scenePhase covers the app, so this tiny edge observes the actual auxiliary
/// window. It releases animation/video owners when hidden, occluded or minimized.
struct TelegramCallWindowVisibility: NSViewRepresentable {
    let receive: @MainActor (Bool)->Void
    func makeNSView(context:Context) -> CallWindowVisibilityProbe { let view = CallWindowVisibilityProbe(); view.receive = receive; return view }
    func updateNSView(_ view:CallWindowVisibilityProbe,context:Context) { view.receive = receive; view.updateVisibility() }
    static func dismantleNSView(_ view:CallWindowVisibilityProbe,coordinator:()) { view.stop() }
}
final class CallWindowVisibilityProbe: NSView {
    var receive: (@MainActor (Bool)->Void)?
    private var observers: [NSObjectProtocol] = []
    private var last: Bool?
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); removeObservers()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification,NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in Task { @MainActor in self?.updateVisibility() } })
            }
        }
        updateVisibility()
    }
    func updateVisibility() {
        let visible = window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor
        guard last != visible else { return }; last = visible
        Task { @MainActor [weak self] in guard let self,self.last == visible else { return }; self.receive?(visible) }
    }
    func stop() { last = nil; removeObservers(); receive = nil }
    private func removeObservers() { for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = [] }
    isolated deinit { removeObservers() }
}

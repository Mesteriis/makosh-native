import SwiftUI
import AppKit
import Combine
import CoreImage
import MakoshTelegram

/// App-owned window edge. Call state and device ownership stay in the controller.
@MainActor final class TelegramCallWindows: NSObject, ObservableObject, NSWindowDelegate {
    private struct Entry {
        weak var controller: TelegramCallController?
        let synthetic: Bool
        let avatars: TelegramAvatarStore?
        let observation: AnyCancellable
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var window: NSWindow?
    private var shown: String?
    private let ringtone = TelegramCallRingtone()
    func register(_ controller: TelegramCallController, synthetic: Bool, avatars: TelegramAvatarStore? = nil) {
        let key = ObjectIdentifier(controller)
        guard entries[key] == nil else { return }
        let observation = controller.$call.combineLatest(controller.$incoming, controller.$incomingReady).sink { [weak self] _, _, _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        entries[key] = Entry(controller: controller, synthetic: synthetic, avatars: avatars, observation: observation)
        reconcile()
    }
    func unregister(_ controller: TelegramCallController) {
        if let call = controller.call, call.isActive { controller.end(callID: call.id) }
        entries.removeValue(forKey: ObjectIdentifier(controller)); reconcile()
    }
    func show(_ controller: TelegramCallController) {
        guard let entry = entries[ObjectIdentifier(controller)] else { return }
        present(controller, synthetic: entry.synthetic, force: true)
    }
    private func reconcile() {
        entries = entries.filter { $0.value.controller != nil }
        let values = Array(entries.values)
        let chosen = values.first { $0.controller?.call?.isActive == true }
            ?? values.first { $0.controller?.incomingReady == true && $0.controller?.incoming.isEmpty == false }
            ?? values.first { $0.controller?.call != nil }
        guard let chosen, let controller = chosen.controller else {
            ringtone.stop()
            window?.orderOut(nil); window?.contentView = nil; shown = nil; return
        }
        ringtone.update(call:controller.call,incoming:controller.incoming,ready:controller.incomingReady)
        present(controller, synthetic: chosen.synthetic, force: false)
    }
    private func present(_ controller: TelegramCallController, synthetic: Bool, force: Bool) {
        guard let id = controller.call?.id ?? controller.incoming.first?.id else { return }
        let key = "\(ObjectIdentifier(controller))-\(id)"
        if window == nil {
            let value = NSWindow(contentRect: .init(x: 0, y: 0, width: 358, height: 477), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            value.title = "Звонок Telegram — Макош"; value.minSize = .init(width: 358, height: 477)
            value.titlebarAppearsTransparent = true; value.titleVisibility = .hidden
            value.isReleasedWhenClosed = false; value.delegate = self; value.center(); window = value
        }
        if shown != key {
            shown = key
            window?.contentView = NSHostingView(rootView: TelegramCallWindowView(controller: controller, synthetic: synthetic, avatars: entries[ObjectIdentifier(controller)]?.avatars))
            window?.makeKeyAndOrderFront(nil)
        } else if force { window?.makeKeyAndOrderFront(nil) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
}

struct TelegramCallCompactView: View {
    @ObservedObject var controller: TelegramCallController
    @EnvironmentObject private var windows: TelegramCallWindows
    var body: some View {
        if let call = controller.call {
            HStack(spacing: 12) {
                Button { windows.show(controller) } label: { TimelineView(.periodic(from: .now, by: 1)) { _ in Label(call.title + " · " + callStatus(call), systemImage: "phone.fill").lineLimit(1) } }
                    .buttonStyle(.plain).accessibilityIdentifier("telegram.call.show")
                Spacer(minLength: 0)
                if call.isActive {
                    Button { _ = controller.setMuted(!call.muted, callID: call.id) } label: { Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill") }
                        .disabled(call.phase != .connected && call.phase != .reconnecting).accessibilityLabel(call.muted ? "Включить микрофон" : "Выключить микрофон")
                        .accessibilityIdentifier("telegram.call.compact.mute")
                    Button("Завершить", role: .destructive) { controller.end(callID: call.id) }.accessibilityIdentifier("telegram.call.compact.end")
                } else {
                    Button("Закрыть", action: controller.dismissEnded).disabled(controller.isReleasingMedia).accessibilityIdentifier("telegram.call.compact.dismiss")
                }
            }.padding(.horizontal, 14).frame(height: 38).background(Color.accentColor.opacity(0.16))
        }
        ForEach(controller.incoming.filter { $0.id != controller.call?.id }) { incoming in
            HStack {
                Button { windows.show(controller) } label: { Label("Входящий · " + incoming.title, systemImage: incoming.isVideo ? "video.fill" : "phone.fill").lineLimit(1) }.buttonStyle(.plain)
                Spacer()
                Button("Отклонить", role: .destructive) { _ = controller.decline(incoming) }.accessibilityIdentifier("telegram.call.incoming.decline")
                Button("Ответить") { _ = controller.accept(incoming, video: false) }.disabled(controller.isBusy || !controller.incomingReady).accessibilityIdentifier("telegram.call.incoming.acceptAudio")
            }.padding(10).background(Color.accentColor.opacity(0.12))
        }
    }
}
struct TelegramCallButtons: View {
    @ObservedObject var controller: TelegramCallController
    let hasTarget: Bool
    var body: some View {
        if hasTarget {
            Menu {
                Button("Аудиозвонок") { start(false) }.disabled(controller.peerStatus != .ready || controller.peer?.canVoice != true).accessibilityIdentifier("telegram.call.start.audio")
                Button("Видеозвонок") { start(true) }.disabled(controller.peerStatus != .ready || controller.peer?.canVideo != true).accessibilityIdentifier("telegram.call.start.video")
                if controller.peerStatus == .failed || controller.peerStatus == .timedOut {
                    Text("Не удалось проверить возможность звонка")
                    Button("Проверить снова", action: controller.refreshPeer).accessibilityIdentifier("telegram.call.peer.retry")
                }
            } label: { Image(systemName: "phone").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().disabled(controller.isBusy || !controller.permitsStart())
                .help("Позвонить").accessibilityLabel("Позвонить").accessibilityIdentifier("telegram.call.menu")
        }
    }
    private func start(_ video: Bool) {
        guard let peer = controller.peer else { return }
        _ = controller.startOutgoing(basis: peer, video: video, contextID: controller.peerContextID)
    }
}

private struct TelegramCallWindowView: View {
    @ObservedObject var controller: TelegramCallController
    let synthetic: Bool
    let avatars: TelegramAvatarStore?
    @State private var audioSettingsPresented = false
    @State private var windowVisible = false
    @State private var previewDrag = CGSize.zero
    @StateObject private var presentation = TelegramCallVideoPresentation()
    @AppStorage(TelegramAppearancePreferences.preferenceKey) private var appearanceRaw = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var videoConnected: Bool { controller.call?.phase == .connected && controller.remoteVideoEnabled && controller.remoteFrame != nil }
    private var active: Bool { controller.call.map { $0.isActive && $0.phase != .ending } ?? !controller.incoming.isEmpty }
    private var animate: Bool { TelegramCallDecoration.animates(active:active,visible:windowVisible,enabled:((try? TelegramAppearancePreferences.decode(appearanceRaw)) ?? .init()).animationsEnabled,reduceMotion:reduceMotion) }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.15, green: 0.22, blue: 0.28), Color(red: 0.08, green: 0.12, blue: 0.19)], startPoint: .top, endPoint: .bottom)
                .overlay {
                    if let avatars, let id = controller.call?.peerID ?? controller.incoming.first?.peerID {
                        GeometryReader { geometry in
                            TelegramChatAvatar(title: title, peerID: id, store: avatars, size: max(geometry.size.width, geometry.size.height))
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .blur(radius: 45).overlay(Color.black.opacity(0.6)).clipped()
                        }.allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            if let frame = controller.remoteFrame, controller.remoteVideoEnabled {
                CallVideoImage(frame: frame).accessibilityLabel("Видео собеседника").accessibilityIdentifier("telegram.call.remoteVideo")
            }
            VStack(spacing: 14) {
                HStack { Spacer(); Button { audioSettingsPresented = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).accessibilityLabel("Аудиоустройства следующего звонка").accessibilityIdentifier("telegram.call.audio.open") }.padding(.top, 26)
                if synthetic { Text("СИНТЕТИЧЕСКАЯ ПРОВЕРКА · БЕЗ УСТРОЙСТВ").font(.caption2.bold()).padding(.top, 25).accessibilityIdentifier("telegram.call.synthetic") }
                Spacer(minLength: 10)
                if controller.remoteFrame == nil {
                    ZStack {
                        TelegramCallDecorationView(animate:animate,connected:controller.call?.phase == .connected)
                        if let avatars,let id = controller.call?.peerID ?? controller.incoming.first?.peerID {
                            TelegramCallAvatar(title:title,peerID:id,store:avatars,enabled:animate)
                        } else {
                            Text(String(title.prefix(1)).uppercased()).font(.system(size:56,weight:.light)).frame(width:110,height:110).background(Color.white.opacity(0.12),in:Circle())
                        }
                    }.frame(height:140)
                }
                Text(title).font(.title2.weight(.medium)).lineLimit(2).multilineTextAlignment(.center).accessibilityIdentifier("telegram.call.title")
                if let call = controller.call {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in Text(callStatus(call)).font(.callout).accessibilityIdentifier("telegram.call.status") }
                    if let explanation = call.explanation { Text(explanation).font(.caption).multilineTextAlignment(.center).accessibilityIdentifier("telegram.call.explanation") }
                    if let fingerprint = call.fingerprint { fingerprintView(fingerprint) }
                    Spacer(minLength: 10)
                    activeControls(call)
                        .anchorPreference(key:TelegramCallPreviewExclusions.self,value:.bounds) { [$0] }
                } else if let incoming = controller.incoming.first {
                    Text(incoming.isVideo ? "Входящий видеозвонок" : "Входящий звонок").accessibilityIdentifier("telegram.call.status")
                    Spacer(minLength: 10)
                    HStack(spacing: 35) {
                        control("Отклонить", "phone.down.fill", .red, "decline") { _ = controller.decline(incoming) }
                        control("Ответить", "phone.fill", .green, "acceptAudio") { _ = controller.accept(incoming, video: false) }.disabled(controller.isBusy || !controller.incomingReady)
                    }
                    if incoming.isVideo {
                        Button("Ответить с видео") { _ = controller.accept(incoming, video: true) }.disabled(controller.isBusy || !controller.incomingReady).accessibilityIdentifier("telegram.call.acceptVideo")
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 28)
                .opacity(presentation.controlsVisible ? 1 : 0).allowsHitTesting(presentation.controlsVisible).accessibilityHidden(!presentation.controlsVisible)
            if !presentation.controlsVisible {
                VStack { Spacer(); Button("Показать управление") { presentation.activity() }.keyboardShortcut(.space,modifiers:[]).accessibilityIdentifier("telegram.call.controls.reveal").padding(12).anchorPreference(key:TelegramCallPreviewExclusions.self,value:.bounds) { [$0] } }
            }
        }.foregroundStyle(.white).preferredColorScheme(.dark).frame(minWidth: 358, minHeight: 477)
            .overlayPreferenceValue(TelegramCallPreviewExclusions.self) { exclusions in
                GeometryReader { geometry in
                    if let frame = controller.localFrame { localPreview(frame,avoiding:exclusions.map { geometry[$0] }) }
                }
            }
            .background(TelegramCallWindowVisibility { windowVisible = $0; updatePresentation() })
            .contentShape(Rectangle()).onContinuousHover { phase in if case .active = phase { presentation.activity() } }
            .onTapGesture { presentation.activity() }.focusable().focusEffectDisabled()
            .onKeyPress { _ in presentation.activity(); return .ignored }
            .onAppear { updatePresentation() }.onDisappear { presentation.stop() }
            .onChange(of:controller.call) { _,_ in updatePresentation() }
            .onChange(of:videoConnected) { _,_ in updatePresentation() }
            .onChange(of:voiceOver) { _,_ in updatePresentation() }
            .onChange(of:audioSettingsPresented) { _,_ in updatePresentation() }
            .sheet(isPresented: $audioSettingsPresented) {
                VStack { HStack { Text("Аудиоустройства").font(.headline); Spacer(); Button("Готово") { audioSettingsPresented = false } }.padding()
                    TelegramCallAudioSettingsView(synthetic: synthetic)
                }.frame(width: 480, height: 420)
            }
    }
    private var title: String { controller.call?.title ?? controller.incoming.first?.title ?? "Telegram" }
    private func updatePresentation() { presentation.update(callID:controller.call?.id,videoConnected:videoConnected && windowVisible && !audioSettingsPresented,voiceOver:voiceOver) }
    private func cornerTitle(_ corner:TelegramCallPreviewCorner) -> String {
        switch corner { case .topLeading: "Сверху слева"; case .topTrailing: "Сверху справа"; case .bottomLeading: "Снизу слева"; case .bottomTrailing: "Снизу справа" }
    }
    private func localPreview(_ frame:CVPixelBuffer,avoiding obstacles:[CGRect]) -> some View {
        GeometryReader { geometry in
            let size = CGSize(width:96,height:72)
            let available = CGSize(width:geometry.size.width,height:max(72,geometry.size.height-40))
            if let origin = presentation.origin(in:available,preview:size,avoiding:obstacles.map { $0.offsetBy(dx:0,dy:-40) }) {
            let x = min(max(0,origin.x+previewDrag.width),max(0,available.width-size.width))
            let y = min(max(0,origin.y+previewDrag.height),max(0,available.height-size.height))
            CallVideoImage(frame:frame).scaleEffect(x:-1,y:1).allowsHitTesting(false)
                .frame(width:size.width,height:size.height).clipShape(RoundedRectangle(cornerRadius:8))
                .contentShape(Rectangle()).position(x:x+size.width/2,y:y+40+size.height/2)
                .gesture(DragGesture(minimumDistance:2).onChanged { previewDrag = $0.translation; presentation.activity() }.onEnded {
                    presentation.move(to:CGPoint(x:origin.x+$0.translation.width,y:origin.y+$0.translation.height),in:available,preview:size); previewDrag = .zero
                })
                .contextMenu { ForEach(TelegramCallPreviewCorner.allCases,id:\.self) { corner in Button(cornerTitle(corner)) { presentation.select(corner) } } }
                .accessibilityElement(children:.ignore).accessibilityLabel("Ваше видео · \(cornerTitle(presentation.corner))")
                .accessibilityAdjustableAction { direction in
                    let all = TelegramCallPreviewCorner.allCases,index = all.firstIndex(of:presentation.corner) ?? 0
                    presentation.select(all[(index+(direction == .increment ? 1 : all.count-1))%all.count])
                }.accessibilityIdentifier("telegram.call.localVideo")
            }
        }
    }
    @ViewBuilder private func activeControls(_ call: TelegramCallSnapshot) -> some View {
        if call.isActive {
            HStack(alignment: .top, spacing: 26) {
                control(call.muted ? "Вкл. микрофон" : "Микрофон", call.muted ? "mic.slash.fill" : "mic.fill", .gray, "mute") { _ = controller.setMuted(!call.muted, callID: call.id) }
                    .disabled(![.connected, .reconnecting].contains(call.phase))
                control(call.videoEnabled ? "Без видео" : "Камера", call.videoEnabled ? "video.fill" : "video.slash.fill", .gray, "video") { Task { _ = await controller.setVideo(!call.videoEnabled, callID: call.id) } }
                    .disabled(![.connected, .reconnecting].contains(call.phase) || (!call.videoEnabled && !call.canVideo) || controller.isChangingVideo)
                control("Завершить", "phone.down.fill", .red, "end") { controller.end(callID: call.id) }.disabled(call.phase == .ending)
            }
        } else {
            HStack(spacing: 26) {
                control("Позвонить снова", "phone.fill", .green, "recall") { _ = controller.recall(callID: call.id, video: false) }
                    .disabled(!controller.canRecall(callID: call.id))
                if controller.peer?.canVideo == true {
                    control("Видеозвонок", "video.fill", .green, "recallVideo") { _ = controller.recall(callID: call.id, video: true) }
                        .disabled(!controller.canRecall(callID: call.id))
                }
            }
            Button(controller.isReleasingMedia ? "Освобождение устройств…" : "Закрыть", action: controller.dismissEnded)
                .disabled(controller.isReleasingMedia).accessibilityIdentifier("telegram.call.dismiss")
        }
    }
    private func control(_ title: String, _ symbol: String, _ color: Color, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) { Image(systemName: symbol).font(.system(size: 21)).frame(width: 52, height: 52).background(color.opacity(0.85), in: Circle()); Text(title).font(.caption).lineLimit(1) }
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier("telegram.call." + id)
    }
    private func fingerprintView(_ value: Data) -> some View {
        DisclosureGroup {
            Text("Сравните этот отпечаток с собеседником.").font(.caption)
            Text(value.map { String(format: "%02X", $0) }.joined().enumerated().map { index, char in String(char) + (index % 16 == 15 ? "\n" : "") }.joined().trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("telegram.call.fingerprint")
        } label: {
            if let emoji = TelegramCallKey.emoji(value) { Text(emoji).font(.system(size:30)).accessibilityLabel("Ключ звонка: \(emoji)").accessibilityIdentifier("telegram.call.fingerprint.emoji") }
            else { Text("Ключ звонка") }
        }.font(.caption).frame(maxWidth: 240)
            .anchorPreference(key:TelegramCallPreviewExclusions.self,value:.bounds) { [$0] }
    }
}
private func callStatus(_ call: TelegramCallSnapshot) -> String {
    switch call.phase {
    case .authorizing: return call.videoEnabled ? "Разрешение на микрофон и камеру…" : "Разрешение на микрофон…"
    case .validating: return "Проверка собеседника…"
    case .requesting: return call.outgoing ? (call.ringing ? "Ожидание ответа…" : "Вызов…") : "Соединение…"
    case .connecting: return "Соединение…"
    case .reconnecting: return "Восстановление соединения…"
    case .connected:
        let elapsed = max(0, Int(Date().timeIntervalSince(call.connectedAt ?? Date())))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    case .ending: return "Завершение…"
    case .ended: return "Звонок завершён"
    case .failed: return "Звонок не установлен"
    }
}
private struct CallVideoImage: NSViewRepresentable {
    let frame: CVPixelBuffer
    func makeNSView(context: Context) -> CallVideoSurface { CallVideoSurface() }
    func updateNSView(_ view: CallVideoSurface, context: Context) { view.display(frame) }
    static func dismantleNSView(_ view: CallVideoSurface, coordinator: ()) { view.close() }
}
private final class CallVideoSurface: NSView {
    private lazy var renderer: TelegramCallFrameRenderer = TelegramCallFrameRenderer { [weak self] token, image in
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.renderer.acknowledge() }
            guard self.renderer.isCurrent(token) else { return }
            self.layer?.contents = image
        }
    }
    private var last: CVPixelBuffer?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.contentsGravity = .resizeAspect; layer?.backgroundColor = NSColor.black.cgColor }
    required init?(coder: NSCoder) { nil }
    func display(_ frame: CVPixelBuffer) {
        guard last !== frame else { return }; last = frame
        renderer.submit(frame)
    }
    func close() { renderer.close(); last = nil; layer?.contents = nil }
    isolated deinit { renderer.close() }
}

import AppKit
import Combine
import MakoshWhatsApp
import SwiftUI

struct WhatsAppCallView: View {
  @ObservedObject var model: WhatsAppCallController
  let call: WhatsAppCallSnapshot
  @State private var invitedParticipant=""
  var body: some View {
    VStack(spacing: 14) {
      Group {
        Text(call.peer).font(.headline).textSelection(.enabled)
        Text(label(call.state)).font(.callout).foregroundStyle(.secondary)
        if call.group != nil {WhatsAppGroupCallGrid(model:model,call:call)}
        else if call.video || call.remoteVideo {
          ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.black)
            if let image = model.images.remote {
              Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
              Text(
                call.state == "preview"
                  ? "Синтетическое видео · без камеры" : "Ожидаем видео собеседника"
              ).foregroundStyle(.white.opacity(0.7)).frame(
                maxWidth: .infinity, maxHeight: .infinity)
            }
            if let image = model.images.local {
              Image(decorative: image, scale: 1).resizable().scaledToFit().frame(
                width: 150, height: 112
              ).background(.black).clipShape(RoundedRectangle(cornerRadius: 10)).padding(12)
            }
          }.aspectRatio(4 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
          Image(systemName: "person.crop.circle.fill").font(.system(size: 70)).foregroundStyle(
            .green
          ).padding(12)
        }
        if call.group==nil,call.state=="active" {
          HStack {TextField("JID нового участника",text:$invitedParticipant).textFieldStyle(.roundedBorder);Button("Пригласить") {let jid=invitedParticipant;Task {await model.invite(jid:jid,ringOnly:false)}}.disabled(!WhatsAppGroupCallTargets.isUser(invitedParticipant))}
        }
        HStack(spacing: 20) {
          if call.incoming, call.state == "ringing" {
            Button("Принять аудио") { model.accept(video: false) }.tint(.green)
            if call.video { Button("Принять видео") { model.accept(video: true) }.tint(.green) }
          } else {
            Button {
              Task { await model.setMuted(!call.muted) }
            } label: {
              Label(
                call.muted ? "Включить звук" : "Микрофон",
                systemImage: call.muted ? "mic.slash.fill" : "mic.fill")
            }.disabled(["permission", "preparing", "preview"].contains(call.state))
            Button {
              Task { await model.setVideo(!call.video) }
            } label: {
              Label(
                call.video ? "Выключить видео" : call.videoRequested ? "Принять видео" : "Видео",
                systemImage: call.video ? "video.fill" : "video")
            }.disabled(["permission", "preparing", "preview"].contains(call.state))
          }
          Button(role: .destructive) {
            Task { await model.end() }
          } label: {
            Label(
              call.incoming && call.state == "ringing" ? "Отклонить" : call.group != nil ? "Покинуть звонок":"Завершить",
              systemImage: "phone.down.fill")
          }.tint(.red).accessibilityIdentifier("whatsapp.call.end")
        }.buttonStyle(.borderedProminent)
      }
    }.padding(20).frame(minWidth: 340, maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
  }
  private func label(_ state: String) -> String {
    switch state {
    case "ringing": "Входящий звонок"
    case "permission": "Разрешение доступа к устройствам…"
    case "preparing": "Подготовка звонка…"
    case "calling": "Вызов…"
    case "connecting": "Соединение…"
    case "active": "Звонок соединён"
    case "preview": "Тестовое окно · без сети и устройств"
    default: "Звонок завершён"
    }
  }
}

/// A narrow floating-window bridge. SwiftUI/controller own every call value;
/// AppKit owns only the panel and its close gesture.
@MainActor final class WhatsAppCallPanel: NSObject, ObservableObject, NSWindowDelegate {
  private let controller: WhatsAppCallController
  private var panel: NSPanel?, subscription: AnyCancellable?
  private var video = false
  init(controller: WhatsAppCallController) {
    self.controller = controller
    super.init()
    // @Published emits in willSet; construct the first host only once the
    // controller's committed value is available to its observed SwiftUI view.
    subscription = controller.$call.receive(on: RunLoop.main).sink { [weak self] call in
      guard self?.controller.call == call else { return }
      self?.update(call)
    }
  }
  isolated deinit {
    subscription?.cancel()
    panel?.orderOut(nil)
    panel?.contentView = nil
    panel?.delegate = nil
  }
  private func update(_ call: WhatsAppCallSnapshot?) {
    guard let call else {
      panel?.orderOut(nil)
      return
    }
    if panel == nil {
      let panel = NSPanel(
        contentRect: .init(x: 0, y: 0, width: 380, height: 280),
        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered,
        defer: false)
      panel.title = "Звонок WhatsApp"
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.level = .floating
      panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
      panel.minSize = .init(width: 360, height: 250)
      let host = NSHostingController(rootView: WhatsAppCallView(model: controller, call: call))
      host.sizingOptions = []
      panel.contentViewController = host
      panel.delegate = self
      panel.center()
      self.panel = panel
    }
    (panel?.contentViewController as? NSHostingController<WhatsAppCallView>)?.rootView = WhatsAppCallView(model: controller, call: call)
    let showVideo = call.video || call.remoteVideo || call.group != nil
    if showVideo != video {
      video = showVideo
      panel?.setContentSize(
        showVideo ? .init(width: 680, height: 620) : .init(width: 380, height: 280))
    }
    if panel?.isVisible != true { panel?.makeKeyAndOrderFront(nil) }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    Task { await controller.end() }
    return false
  }
}
struct WhatsAppCallHost: ViewModifier {
  @ObservedObject var controller: WhatsAppCallController
  @StateObject private var panel: WhatsAppCallPanel
  init(_ controller: WhatsAppCallController) {
    self.controller = controller
    _panel = StateObject(wrappedValue: WhatsAppCallPanel(controller: controller))
  }
  func body(content: Content) -> some View {
    content.onAppear { _ = panel }.alert(
      "Звонок WhatsApp",
      isPresented: Binding(
        get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })
    ) {
      Button("Понятно") { controller.error = nil }
    } message: {
      Text(controller.error ?? "")
    }
  }
}
struct WhatsAppCallDevicesView: View {
  @ObservedObject var model: WhatsAppCallController
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Устройства звонка").font(.title2.bold())
        Spacer()
        Button("Закрыть") { dismiss() }
      }
      if let list = model.deviceList {
        picker("Микрофон", selection: $model.devices.input, values: list.inputs)
        picker("Динамики", selection: $model.devices.output, values: list.outputs)
        picker("Камера", selection: $model.devices.camera, values: list.cameras)
      } else {
        Text("Системные устройства используются по умолчанию.").foregroundStyle(.secondary)
      }
      Text("Выбор действует для следующего звонка.").font(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(width: 440).task { await model.loadDevices() }
  }
  private func picker(_ name: String, selection: Binding<String>, values: [WhatsAppCallDevice])
    -> some View
  {
    Picker(name, selection: selection) {
      Text("Системное по умолчанию").tag("")
      ForEach(values) { Text($0.name).tag($0.id) }
    }.disabled(model.call != nil)
  }
}

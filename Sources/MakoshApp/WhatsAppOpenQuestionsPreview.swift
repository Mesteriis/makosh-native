#if DEBUG
  import Foundation
  import MakoshCore
  import MakoshWhatsApp
  import SwiftUI

  struct WhatsAppOpenQuestionsPreview: View {
    @State private var model: WhatsAppWorkspaceModel?
    @State private var root: URL?
    @State private var error: String?
    @State private var largeText = false
    @State private var picker = false
    var body: some View {
      Group {
        if let model, let root {
          WorkspaceView(syntheticWhatsApp: model).dynamicTypeSize(
            largeText ? .accessibility1 : .large
          )
          .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
              Text("СИНТЕТИЧЕСКАЯ QA · без сети WhatsApp и устройств").font(.caption.bold())
              Toggle("Крупный текст", isOn: $largeText).toggleStyle(.button)
              Menu("Сценарии QA") {
                Button("Пакет 10 файлов") {
                  Task { await attach(model, root: root, photo: false, asFiles: true) }
                }
                Button("Смешанные 10 вложений") {
                  Task { await attach(model, root: root, photo: false, asFiles: false) }
                }
                Button("Фото в редактор") {
                  Task { await attach(model, root: root, photo: true, asFiles: false) }
                }
                Button("Выбор участников") { picker = true }
                Button("Группа · макет") { model.calls.previewGroup() }
                Button("Личный звонок · макет") { model.calls.preview() }
              }.accessibilityIdentifier("whatsapp.qa.scenarios")
            }
          }
          .sheet(isPresented: $picker) {
            if let account = model.selectedAccountID {
              WhatsAppGroupCallPicker(
                worker: model.notificationWorker, accountID: account, groupJID: "test-team@g.us",
                video: true
              ) { _ in model.calls.previewGroup() }
            }
          }
        } else if let error {
          Text(error).padding(24).accessibilityIdentifier("whatsapp.qa.configurationRequired")
        } else {
          ProgressView("Проверка отдельной конфигурации WhatsApp QA…")
        }
      }.task {
        guard model == nil, error == nil else { return }
        let args = CommandLine.arguments
        do {
          let configuration = try await BackgroundWork.run {
            try WhatsAppQAIsolation.configuration(arguments: args)
          }
          let service = try await WhatsAppWorker.openQuestionsQA(
            configuration: configuration, arguments: args)
          root = try WhatsAppQAIsolation.root(arguments: args)
          model = WhatsAppWorkspaceModel(worker: service, polling: true, synthetic: true)
        } catch {
          self.error =
            "WhatsApp QA требует локальные PostgreSQL/S3, обе схемы qa_whatsapp_ и отдельный приватный каталог. Провайдер, личные ключи и устройства выключены."
        }
      }
    }
    private func attach(_ model: WhatsAppWorkspaceModel, root: URL, photo: Bool, asFiles: Bool)
      async
    {
      guard let account = model.selectedAccountID, let chat = model.selectedChatID else { return }
      let fixtures = root.appendingPathComponent("fixtures")
      let urls =
        photo
        ? [fixtures.appendingPathComponent("photo.png")]
        : (0..<10).map { fixtures.appendingPathComponent($0 == 0 ? "photo.png" : "file-\($0).txt") }
      await model.composer.attach(urls, asFiles: asFiles, targetAccount: account, targetChat: chat)
      if photo { await model.composer.editPhotos() }
    }
  }
  extension WhatsAppCallController {
    func previewGroup() {
      guard isSyntheticPreviewAllowed, call == nil else { return }
      let participants = (0..<32).map { n in
        WhatsAppCallParticipant(
          jid: "qa\(n)@lid", state: n < 20 ? "connected" : "invited",
          devices: [.init(jid: "qa\(n):2@lid", pid: UInt32(n))], me: n == 0)
      }
      installGroupPreview(
        .init(
          id: "synthetic-group-preview", epoch: 0, peer: "Группа · синтетический макет",
          state: "preview", incoming: false, video: true, remoteVideo: false, videoRequested: false,
          muted: false,
          group: .init(groupJID: "test-team@g.us", rosterRevision: 1, participants: participants)))
    }
  }
#endif

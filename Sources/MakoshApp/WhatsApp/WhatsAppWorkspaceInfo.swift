import MakoshWhatsApp
import SwiftUI

/// Account/chat-scoped read-only context. Provider IDs stay visible when no verified name exists.
struct WhatsAppWorkspaceInfo: View {
  @ObservedObject var model: WhatsAppWorkspaceModel
  let accountID: UUID
  let chat: WhatsAppChat
  @Binding var info: WhatsAppPeerInfo?
  let close: () -> Void
  let settings: () -> Void
  let dossier: () -> Void
  let media: () -> Void
  @State private var busy = false
  @State private var error: String?
  @State private var allMembers = false
  @State private var refresh = 0
  @State private var request = UUID()
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(chat.group ? "О группе" : "О собеседнике").font(.headline)
        Spacer()
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel("Закрыть сведения о чате")
          .accessibilityIdentifier("whatsapp.chat.infoClose")
      }.padding(.horizontal, 18).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack(spacing: 14) {
            WhatsAppAvatarView(name: chat.name, group: chat.group,
              scope: .init(accountID: accountID, jid: chat.id),
              revision: model.status.avatarRevisions?[chat.id] ?? 0,
              epoch: model.status.avatarEpoch ?? 0, worker: model.notificationWorker, cache: model.avatarCache)
              .scaleEffect(1.35).frame(width: 62, height: 68)
            VStack(alignment: .leading, spacing: 6) {
              Text(chat.name).font(.headline).lineLimit(2)
              if let members = info?.members { Text("\(members.count) участников").font(.caption).foregroundStyle(.secondary) }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
          if let about = info?.about, !about.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("Описание").font(.headline)
              Text(about).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
          if busy { ProgressView("Загрузка сведений…").controlSize(.small) }
          if let error {
            Text(error).font(.caption).foregroundStyle(.secondary)
            Button("Повторить") { refresh += 1 }
          }
          if let members = info?.members, chat.group {
            VStack(alignment: .leading, spacing: 12) {
              Text("Участники · \(members.count)").font(.headline)
              ForEach(Array(members.prefix(allMembers ? members.count : 4).enumerated()), id: \.offset) { _, member in
                HStack(spacing: 9) {
                  Image(systemName: member.me ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.title2).foregroundStyle(WorkspaceStyle.accent)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(member.me ? "Вы" : member.jid).lineLimit(1).truncationMode(.middle)
                    if member.admin { Text("Администратор").font(.caption2).foregroundStyle(.secondary) }
                  }
                }
              }
              if members.count > 4 {
                Button(allMembers ? "Свернуть" : "Показать всех") { allMembers.toggle() }
                  .buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent)
                  .accessibilityIdentifier("whatsapp.group.showMembers")
              }
            }
          }
          VStack(spacing: 14) {
            Button(action: media) { Label("Медиа в переписке", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, alignment: .leading) }
              .accessibilityIdentifier("whatsapp.chat.media")
            Button(action: settings) { Label("Настройки чата", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading) }
              .accessibilityIdentifier("whatsapp.chat.settings")
            if !chat.group {
              Button(action: dossier) { Label("Связать с досье", systemImage: "person.text.rectangle").frame(maxWidth: .infinity, alignment: .leading) }
            }
          }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent)
          Text(model.isSynthetic ? "Синтетические данные · без сети" : model.status.label)
            .font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.accessibilityIdentifier("whatsapp.chat.info")
      .task(id: refresh) { await load() }
  }
  private func load() async {
    let token = UUID()
    request = token
    info = nil
    error = nil
    busy = true
    defer { if request == token { busy = false } }
    do {
      let result = try await model.notificationWorker.info(accountID: accountID, chat: chat.id,
        operation: chat.group ? .groupInfo : .userInfo)
      guard request == token, !Task.isCancelled, model.selectedAccountID == accountID,
        model.selectedChatID?.utf8.elementsEqual(chat.id.utf8) == true else { return }
      guard result.jid?.utf8.elementsEqual(chat.id.utf8) == true,
        (result.members?.count ?? 0) <= 10_000 else {
        error = "Сведения пока недоступны."
        return
      }
      info = result
    } catch {
      guard request == token, !Task.isCancelled, model.selectedAccountID == accountID,
        model.selectedChatID?.utf8.elementsEqual(chat.id.utf8) == true else { return }
      self.error = "Не удалось загрузить сведения."
    }
  }
}

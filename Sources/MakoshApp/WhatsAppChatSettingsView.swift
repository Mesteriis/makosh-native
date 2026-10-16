import MakoshWhatsApp
import SwiftUI

struct WhatsAppChatSettingsView: View {
  @ObservedObject var model: WhatsAppActionsModel
  let chat: WhatsAppChat
  let accountID: UUID
  let synthetic: Bool
  let worker: any WhatsAppServing
  let avatarCache: WhatsAppAvatarWindowCache
  var avatarRevision: UInt64 = 0, avatarEpoch: UInt64 = 0
  var dossier: () -> Void = {}
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var about = ""
  @State private var member = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        WhatsAppAvatarView(name: chat.name, group: chat.group, scope: .init(accountID: accountID, jid: chat.id),
          revision: avatarRevision, epoch: avatarEpoch, worker: worker, cache: avatarCache)
        Text(chat.name).font(.title2.bold())
        Spacer()
        Button("Закрыть") { dismiss() }
      }
      Form {
        Section("Файлы") {
          Toggle("Сохранять файлы в S3", isOn: $model.saving)
          Text("Выключение запрещает новые копии. История и ранее сохранённые файлы остаются.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.busy || !model.settingsLoaded)
        Section("Уведомления этого чата") {
          Toggle("Показывать", isOn: $model.rule.show)
          Toggle("Предпросмотр текста", isOn: $model.rule.preview)
          Toggle("Звук", isOn: $model.rule.sound)
          Toggle("При открытом окне", isOn: $model.rule.foreground)
        }
        .disabled(model.busy || !model.settingsLoaded)
        Section {
          Button("Сохранить настройки") {
            Task {
              if model.contextMatches(account: accountID, chat: chat.id) {
                await model.saveSettings()
              }
            }
          }.disabled(model.busy || !model.settingsLoaded).accessibilityIdentifier("whatsapp.settings.save")
        }
        Section(chat.group ? "Группа" : "Собеседник") {
          Text(chat.id).font(.caption).textSelection(.enabled)
          Button("Обновить информацию") {
            Task {
              if model.contextMatches(account: accountID, chat: chat.id) {
                await model.inspect(chat.group ? .groupInfo : .userInfo)
              }
            }
          }.disabled(synthetic || model.busy)
          if let info = model.info {
            if let about = info.about, !about.isEmpty { Text(about).textSelection(.enabled) }
            ForEach(info.members ?? []) { m in
              HStack {
                Text(m.jid).textSelection(.enabled)
                Spacer()
                if m.admin { Text("Администратор").foregroundStyle(.secondary) }
                if m.me { Text("Вы") }
              }
            }.font(.callout)
            if let link = info.link { Text(link).textSelection(.enabled) }
          }
          if !chat.group {
            Button("Связать с досье") {
              if model.contextMatches(account: accountID, chat: chat.id) { dossier() }
            }.accessibilityIdentifier("whatsapp.dossier")
          }
          if chat.group {
            TextField("Название группы", text: $name)
            Button("Изменить название") { command(.init(.groupName, text: name)) }.disabled(
              name.isEmpty)
            TextField("Описание", text: $about)
            Button("Изменить описание") { command(.init(.groupAbout, text: about)) }
            TextField("JID участника", text: $member)
            Menu("Участники") {
              ForEach(["add", "remove", "promote", "demote"], id: \.self) { operation in
                Button(memberLabel(operation)) {
                  var a = WhatsAppAction(.groupUpdate, target: member)
                  a.category = operation
                  command(a)
                }
              }
            }.disabled(member.isEmpty)
            Button("Ссылка приглашения") {
              Task {
                if model.contextMatches(account: accountID, chat: chat.id) {
                  await model.inspect(.groupLink)
                }
              }
            }
            Button("Выйти из группы", role: .destructive) { command(.init(.groupLeave)) }
          } else {
            Button(model.info?.blocked == true ? "Разблокировать" : "Заблокировать") {
              command(.init(.block, on: model.info?.blocked != true))
            }
          }
          Menu("Исчезающие сообщения") {
            ForEach([Int64(0), 86400, 604800, 7_776_000], id: \.self) { v in
              Button(v == 0 ? "Выключить" : "\(v/86400) дн.") {
                command(.init(.ephemeral, duration: v))
              }
            }
          }
          Text("Удаление и исчезновение в WhatsApp не удаляют архив Макоша.").font(.caption)
            .foregroundStyle(.secondary)
        }.disabled(model.busy)
      }.formStyle(.grouped)
      if let error = model.error { Text(error).foregroundStyle(.red) }
      if let text = model.notice { Text(text).foregroundStyle(.secondary) }
    }.padding(20).frame(minWidth: 520, minHeight: 600).task {
      if model.contextMatches(account: accountID, chat: chat.id) { await model.loadSettings() }
    }
  }
  private func command(_ action: WhatsAppAction) {
    Task { await model.perform(action, expectedAccount: accountID, expectedChat: chat.id) }
  }
  private func memberLabel(_ value: String) -> String {
    switch value {
    case "add": "Добавить"
    case "remove": "Удалить из группы"
    case "promote": "Назначить администратором"
    default: "Снять администратора"
    }
  }
}

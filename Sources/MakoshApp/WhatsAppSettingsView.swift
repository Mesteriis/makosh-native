import MakoshWhatsApp
import SwiftUI
import UserNotifications

@MainActor final class WhatsAppSettingsRegistry: ObservableObject {
  private final class Entry {
    weak var model: WhatsAppWorkspaceModel?
    init(_ model: WhatsAppWorkspaceModel) { self.model = model }
  }
  private var entries: [UUID: Entry] = [:]
  @Published private(set) var revision = 0
  var models: [(UUID, WhatsAppWorkspaceModel)] {
    entries.compactMap { id, entry in entry.model.map { (id, $0) } }.sorted {
      $0.0.uuidString < $1.0.uuidString
    }
  }
  func register(_ model: WhatsAppWorkspaceModel, id: UUID) {
    entries[id] = Entry(model)
    revision &+= 1
  }
  func unregister(_ id: UUID) {
    entries.removeValue(forKey: id)
    revision &+= 1
  }
}
struct WhatsAppSettingsHost: ViewModifier {
  @EnvironmentObject private var registry: WhatsAppSettingsRegistry
  @ObservedObject var model: WhatsAppWorkspaceModel
  @State private var id = UUID()
  func body(content: Content) -> some View {
    content.onAppear { registry.register(model, id: id) }.onDisappear { registry.unregister(id) }
  }
}
struct WhatsAppCommonSettingsView: View {
  @EnvironmentObject private var registry: WhatsAppSettingsRegistry
  @State private var selected: UUID?
  var body: some View {
    VStack {
      if registry.models.count > 1 {
        Picker("Рабочее окно", selection: $selected) {
          ForEach(registry.models, id: \.0) { id, model in
            Text(model.accounts.map(\.name).joined(separator: ", ")).tag(Optional(id))
          }
        }
      }
      if let model = registry.models.first(where: { $0.0 == selected })?.1
        ?? registry.models.first?.1
      {
        WhatsAppSettingsView(model: model)
      } else {
        ContentUnavailableView(
          "Откройте WhatsApp", systemImage: "message",
          description: Text("Выберите WhatsApp в боковой панели рабочего окна."))
      }
    }.frame(minWidth: 650, minHeight: 540)
  }
}
struct WhatsAppSettingsView: View {
  @ObservedObject var model: WhatsAppWorkspaceModel
  @EnvironmentObject private var router: ApplicationSystemNotificationRouter
  @State private var pane = "notifications"
  @State private var scope: UUID?
  @StateObject private var preferences: WhatsAppNotificationPreferencesModel
  @State private var notice: String?
  @StateObject private var actions: WhatsAppActionsModel
  @State private var name = ""
  @State private var about = ""
  @State private var privacyCategory = "last"
  @State private var privacyValue = "contacts"
  init(model: WhatsAppWorkspaceModel) {
    self.model = model
    _preferences = StateObject(wrappedValue: .init(worker: model.notificationWorker))
    _actions = StateObject(wrappedValue: .init(worker: model.notificationWorker))
  }
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        Button {
          pane = "notifications"
        } label: {
          Label("Уведомления", systemImage: "bell")
        }
        Button {
          pane = "account"
        } label: {
          Label("Аккаунт", systemImage: "person.crop.circle")
        }
        Button {
          pane = "privacy"
        } label: {
          Label("Конфиденциальность", systemImage: "lock")
        }
        Spacer()
      }.buttonStyle(.plain).padding(16).frame(width: 185).background(.quaternary.opacity(0.35))
      Form {
        Picker("Настройки для", selection: $scope) {
          if pane == "notifications" { Text("Все аккаунты WhatsApp").tag(Optional<UUID>.none) }
          ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) }
        }
        if pane == "notifications" {
          Section("Уведомления") {
            Toggle("Показывать", isOn: $preferences.rule.show)
            Toggle("Предпросмотр текста", isOn: $preferences.rule.preview)
            Toggle("Звук", isOn: $preferences.rule.sound)
            Toggle("При открытом окне", isOn: $preferences.rule.foreground)
            Text(
              "Общие настройки, правила аккаунта и чата ограничивают друг друга. Заглушение в WhatsApp также учитывается."
            ).font(.caption).foregroundStyle(.secondary)
            Button("Сохранить") {
              let account = scope
              Task { await preferences.save(expectedAccount: account) }
            }.disabled(!preferences.loaded || preferences.busy)
            Button("Разрешить уведомления macOS") { Task { await permission() } }
          }
        } else if let scope {
          if pane == "account" {
            Section("Профиль") {
              Button("Загрузить профиль") { inspect(.profile) }
              if let info = actions.info {
                Text(info.jid ?? "").textSelection(.enabled)
                Text(info.name ?? "")
                Text(info.about ?? "")
              }
              TextField("Имя", text: $name)
              Button("Изменить имя") { command(.init(.setName, text: name), account: scope) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              TextField("О себе", text: $about)
              Button("Изменить описание") { command(.init(.setAbout, text: about), account: scope) }
            }
          } else {
            Section("Конфиденциальность") {
              Button("Загрузить текущие правила") { inspect(.privacy) }
              if let rules = actions.info?.rules {
                ForEach(rules.keys.sorted(), id: \.self) { Text("\($0): \(rules[$0] ?? "")") }
              }
              Picker("Кто видит", selection: $privacyCategory) {
                Text("Последний визит").tag("last")
                Text("В сети").tag("online")
                Text("Фото профиля").tag("profile")
                Text("Статусы").tag("status")
                Text("Добавление в группы").tag("groupadd")
                Text("Отчёты о прочтении").tag("readreceipts")
                Text("Звонки").tag("calladd")
              }
              Picker("Значение", selection: $privacyValue) {
                ForEach(privacyValues, id: \.self) { Text(privacyLabel($0)).tag($0) }
              }
              Button("Применить правило") {
                var a = WhatsAppAction(.privacySet)
                a.category = privacyCategory
                a.value = privacyValue
                command(a, account: scope)
              }
            }
          }
        } else {
          Text("Выберите аккаунт")
        }
        if let notice { Text(notice).foregroundStyle(.secondary) }
        if let note = preferences.notice { Text(note).foregroundStyle(.secondary) }
        if let error = actions.error { Text(error).foregroundStyle(.red) }
        if let value = actions.notice { Text(value).foregroundStyle(.secondary) }
      }.formStyle(.grouped).disabled(actions.busy)
    }.onChange(of: scope) { _, value in preferences.reset(value) }.task(
      id: "\(pane):\(scope?.uuidString ?? "global")"
    ) { await load() }.onChange(
      of: privacyCategory
    ) { _, _ in privacyValue = privacyValues.first ?? "none" }
  }
  private var privacyValues: [String] {
    switch privacyCategory {
    case "online": ["all", "match_last_seen"]
    case "readreceipts": ["all", "none"]
    case "calladd": ["all", "known"]
    case "groupadd": ["all", "contacts"]
    default: ["all", "contacts", "none"]
    }
  }
  private func privacyLabel(_ value: String) -> String {
    switch value {
    case "all": "Все"
    case "contacts": "Контакты"
    case "none": "Никто"
    case "known": "Известные контакты"
    default: "Как последний визит"
    }
  }
  private func load() async {
    guard !Task.isCancelled else { return }
    let account = scope
    notice = nil
    actions.setContext(account: account, chat: "self@lid")
    preferences.reset(account)
    if pane == "notifications" { await preferences.load(expectedAccount: account) }
  }
  private func inspect(_ operation: WhatsAppAction.Operation) {
    guard scope != nil else { return }
    Task { await actions.inspect(operation) }
  }
  private func command(_ action: WhatsAppAction, account: UUID) {
    Task { await actions.perform(action, expectedAccount: account, expectedChat: "self@lid") }
  }
  private func permission() async {
    guard router.beginAuthorizationRequest() else { return }
    defer { router.finishAuthorizationRequest() }
    do {
      let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound, .badge,
      ])
      notice = allowed ? "Уведомления разрешены" : "Разрешите уведомления в настройках macOS"
    } catch { notice = "Не удалось запросить разрешение macOS" }
  }
}

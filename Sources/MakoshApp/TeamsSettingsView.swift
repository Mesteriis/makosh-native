import SwiftUI
import UserNotifications
import MakoshTeams

@MainActor final class TeamsSettingsRegistry: ObservableObject {
    private final class Entry { weak var model: TeamsWorkspaceModel?; init(_ model: TeamsWorkspaceModel) { self.model = model } }
    private var entries: [UUID: Entry] = [:]
    @Published private(set) var revision = 0
    var models: [(UUID, TeamsWorkspaceModel)] { entries.compactMap { id, value in value.model.map { (id, $0) } }.sorted { $0.0.uuidString < $1.0.uuidString } }
    func register(_ model: TeamsWorkspaceModel, id: UUID) { entries[id] = Entry(model); revision &+= 1 }
    func unregister(_ id: UUID) { entries[id] = nil; revision &+= 1 }
}
struct TeamsSettingsHost: ViewModifier {
    @EnvironmentObject private var registry: TeamsSettingsRegistry
    @ObservedObject var model: TeamsWorkspaceModel
    @State private var id = UUID()
    func body(content: Content) -> some View { content.onAppear { registry.register(model, id: id) }.onDisappear { registry.unregister(id) } }
}
struct TeamsCommonSettingsView: View {
    @EnvironmentObject private var registry: TeamsSettingsRegistry
    @State private var selected: UUID?
    var body: some View {
        VStack {
            if registry.models.count > 1 { Picker("Рабочее окно", selection: $selected) { ForEach(registry.models, id: \.0) { id, model in Text(model.accounts.map(\.name).joined(separator: ", ")).tag(Optional(id)) } }.pickerStyle(.menu) }
            if let model = registry.models.first(where: { $0.0 == selected })?.1 ?? registry.models.first?.1 { TeamsSettingsView(model: model) }
            else { ContentUnavailableView("Откройте Teams", systemImage: "person.3", description: Text("Выберите Teams в боковой панели рабочего окна.")) }
        }.frame(minWidth: 650, minHeight: 500)
    }
}
struct TeamsSettingsView: View {
    @ObservedObject var model: TeamsWorkspaceModel
    @EnvironmentObject private var router: ApplicationSystemNotificationRouter
    @StateObject private var preferences: TeamsNotificationPreferencesModel
    @StateObject private var system: TeamsSystemNotifications
    @State private var accountID: UUID?
    @State private var selectedConversation: TeamsScope?
    @State private var accountSnapshot: TeamsWorkspaceSnapshot?
    init(model: TeamsWorkspaceModel) {
        self.model = model
        _preferences = StateObject(wrappedValue: TeamsNotificationPreferencesModel(worker: model.notificationWorker))
        _system = StateObject(wrappedValue: TeamsSystemNotifications(worker: model.notificationWorker, center: model.isSynthetic ? TeamsSyntheticNotificationCenter() : UNUserNotificationCenter.current()))
    }
    private var scope: TeamsNotificationScope { selectedConversation.map(TeamsNotificationScope.conversation) ?? accountID.map(TeamsNotificationScope.account) ?? .global }
    var body: some View {
        Form {
            Section("Уведомления Teams") {
                Picker("Настройки для", selection: $accountID) { Text("Все аккаунты Teams").tag(Optional<UUID>.none); ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu).onChange(of: accountID) { _, _ in selectedConversation = nil }
                if accountID != nil {
                    Picker("Беседа", selection: $selectedConversation) { Text("Весь аккаунт").tag(Optional<TeamsScope>.none); ForEach(accountSnapshot?.chats ?? []) { Text($0.displayName).tag(Optional($0.scope)) }; if let snapshot = accountSnapshot, let principal = snapshot.principal { ForEach(snapshot.channels) { channel in Text(channel.displayName).tag(Optional(TeamsScope(accountID: snapshot.accountID, tenantID: principal.tenantID, resource: .channel(teamID: channel.teamID, channelID: channel.id)))) } } }.pickerStyle(.menu)
                }
                TeamsNotificationRuleFields(rule: $preferences.rule).disabled(!preferences.canSave)
                Button("Сохранить уведомления") { Task { await preferences.save(expectedScope: scope); await router.teamsRegistry.revalidate() } }.disabled(!preferences.canSave).accessibilityIdentifier("teams.common.settings.save")
                if let notice = preferences.notice { Text(notice).font(.caption) }
            }
            Section("Разрешение macOS") {
                Text(model.isSynthetic ? "Синтетический центр уведомлений. Разрешения macOS не запрашиваются." : "Используется разрешение обычной сборки Макоша и единый обработчик всех сервисов.").font(.caption).foregroundStyle(.secondary)
                Button("Запросить / обновить разрешение") { Task { await system.requestPermission() } }.disabled(model.isSynthetic)
                if let status = system.status { Text(status).font(.caption) }
            }
            Section("Файлы и архив") { Text("Политика S3 задаётся отдельно в информации каждой беседы. Личные чаты по умолчанию сохраняют файлы, группы и каналы — нет. Для просмотра старых файлов включать S3 заново не требуется.").font(.caption) }
            Section("Аккаунт") { Text(teamsStateTitle(model.snapshot?.state, synthetic: model.isSynthetic)); Text("Календарь, личные Microsoft-аккаунты, звонки и демонстрация экрана в этот перенос не входят.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).task(id: accountID) {
            accountSnapshot = nil
            guard let accountID else { return }
            do { let value = try await model.worker.snapshot(accountID: accountID); guard !Task.isCancelled, self.accountID == accountID else { return }; accountSnapshot = value }
            catch { /* Preference loading reports its own failure; never use another account's list. */ }
        }.task(id: scope) { preferences.reset(scope); await preferences.load(expectedScope: scope) }.onAppear { system.attach(router) }
    }
}

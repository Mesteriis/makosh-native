import SwiftUI
import MakoshTeams

struct TeamsChatSettingsView: View {
    @ObservedObject var model: TeamsWorkspaceModel
    let scope: TeamsScope
    var dossier: (TeamsPerson) -> Void
    @StateObject private var preferences: TeamsConversationPreferencesModel
    @Environment(\.dismiss) private var dismiss
    init(model: TeamsWorkspaceModel, scope: TeamsScope, dossier: @escaping (TeamsPerson) -> Void) {
        self.model = model; self.scope = scope; self.dossier = dossier
        _preferences = StateObject(wrappedValue: TeamsConversationPreferencesModel(worker: model.worker))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(model.title).font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            Form {
                Section("Уведомления этой беседы") {
                    TeamsNotificationRuleFields(rule: $preferences.rule).disabled(!preferences.canSave)
                    Text("Общие правила и правила аккаунта могут дополнительно ограничивать уведомления.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Файлы") {
                    Toggle("Сохранять файлы в S3", isOn: $preferences.savingFiles).disabled(!preferences.canSave).accessibilityIdentifier("teams.settings.s3")
                    Text("Выключение запрещает любые новые копии. История сообщений и сохранённые объекты остаются. Для ветки действует политика её канала.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Досье") {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, person in Button(person.displayName.isEmpty ? "Собеседник" : person.displayName) { dossier(person); dismiss() }.disabled(person.tenantID.isEmpty).accessibilityIdentifier("teams.dossier.link") }
                    if people.isEmpty { Text("В сохранённой переписке пока нет подтверждённого профиля человека.").foregroundStyle(.secondary) }
                }
                Button("Сохранить настройки") { Task { await preferences.save(expectedScope: scope) } }.disabled(!preferences.canSave).accessibilityIdentifier("teams.settings.save")
                if let notice = preferences.notice { Text(notice).font(.caption) }
                if preferences.busy { ProgressView() }
            }.formStyle(.grouped)
        }.padding(20).frame(width: 590, height: 580).task(id: scope) { preferences.reset(scope); await preferences.load(expectedScope: scope) }
    }
    private var people: [TeamsPerson] {
        var seen = Set<String>()
        return (model.chats.first { $0.scope == scope }?.members ?? model.messages.compactMap(\.author)).filter { seen.insert($0.tenantID + ":" + $0.userID).inserted }
    }
}
struct TeamsNotificationRuleFields: View {
    @Binding var rule: TeamsNotificationRule
    var body: some View {
        Toggle("Показывать уведомления", isOn: $rule.show)
        Toggle("Предпросмотр текста", isOn: $rule.preview)
        Toggle("Звук", isOn: $rule.sound)
        Toggle("При активном окне Макоша", isOn: $rule.foreground)
    }
}

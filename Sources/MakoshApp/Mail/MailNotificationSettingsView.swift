import SwiftUI
import MakoshMail
import UserNotifications

struct MailNotificationSettingsView: View {
    @ObservedObject var model: MailWorkspaceModel
    @ObservedObject private var controller: MailNotificationController
    @EnvironmentObject private var system: MailSystemNotifications
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    let scope: MailNotificationScope
    @State private var rule: MailNotificationRule
    @State private var showWhileActive: Bool
    init(model: MailWorkspaceModel, scope: MailNotificationScope, embedded: Bool = false) {
        self.embedded = embedded
        self.model = model
        self.scope = scope
        controller = model.notifications
        let preferences = model.notifications.preferences
        _rule = State(initialValue: scope == .global ? preferences.global : preferences.overrides[scope.id] ?? .init())
        _showWhileActive = State(initialValue: preferences.showWhileActive)
    }
    private var title: String {
        switch scope {
        case .global: "Вся почта"
        case .account(let id): model.accounts.first { $0.id == id }?.displayName ?? "Аккаунт"
        case .folder(let id, let path): model.folders.first { $0.accountID == id && $0.path == path }?.title ?? path
        case .sender(_, let address): address
        }
    }
    private var authorizationTitle: String {
        switch system.authorization {
        case .authorized, .provisional: "Разрешены"
        case .denied: "Выключены в macOS"
        case .notDetermined: "Разрешение ещё не запрошено"
        default: "Недоступны"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded { Text("Уведомления · \(title)").font(.title2.bold()).lineLimit(2) }
            Form {
                Section("Новые входящие письма") {
                    Toggle("Показывать уведомления", isOn: $rule.enabled).accessibilityIdentifier("mail.notifications.enabled")
                    Toggle("Показывать отправителя и тему", isOn: $rule.previews).accessibilityIdentifier("mail.notifications.previews")
                    Toggle("Звук", isOn: $rule.sound).accessibilityIdentifier("mail.notifications.sound")
                    if scope == .global {
                        Toggle("Показывать, когда окно Макоша активно", isOn: $showWhileActive).accessibilityIdentifier(
                            "mail.notifications.foreground")
                    } else {
                        Text(
                            "Ограничения всей почты, аккаунта, папки и отправителя действуют вместе. Включение здесь не отменяет запрет на другом уровне."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Button("Сбросить отдельную настройку") { Task { await save(nil) } }.accessibilityIdentifier(
                            "mail.notifications.reset")
                    }
                    Text(
                        "Первая загрузка истории не создаёт уведомлений. Настройки отправителя действуют только внутри выбранного почтового аккаунта."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Сохранить") { Task { await save(rule) } }.keyboardShortcut(.defaultAction)
                            .buttonStyle(WorkspaceButtonStyle(prominent: true))
                            .disabled(model.busy).accessibilityIdentifier("mail.notifications.save")
                    }
                }
                Section("Системные уведомления") {
                    LabeledContent("macOS", value: authorizationTitle)
                    HStack {
                        Button("Запросить разрешение") { system.requestAuthorization() }.disabled(system.requesting)
                        Button("Настройки macOS…") { system.openSystemSettings() }
                        Button("Обновить") { system.refreshAuthorization() }
                    }
                    if let status = system.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }.formStyle(WorkspaceFormStyle()).disabled(model.busy)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            if !embedded {
                HStack {
                    Spacer()
                    Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }.padding(embedded ? 0 : 24).frame(
            minWidth: 570, maxWidth: embedded ? .infinity : 570, minHeight: 510, maxHeight: embedded ? .infinity : 570
        )
        .background { WorkspaceBackdrop(intensity: 0.4) }
        .onAppear { system.refreshAuthorization() }
    }
    private func save(_ value: MailNotificationRule?) async {
        await model.setNotificationRule(scope: scope, rule: value, showWhileActive: scope == .global ? showWhileActive : nil)
        if model.error == nil, !embedded { dismiss() }
    }
}

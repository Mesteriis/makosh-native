import MakoshJira
import MakoshTasks
import SwiftUI

/// Settings → Задачи: the Jira sites Makosh mirrors.
struct TasksSettingsView: View {
    @EnvironmentObject private var host: TasksHost

    var body: some View {
        if let model = host.model {
            TasksSettingsForm(model: model).padding(20)
        } else {
            Text("Раздел «Задачи» откроется вместе с рабочим окном.").padding(24)
        }
    }
}

struct TasksSettingsForm: View {
    @ObservedObject var model: TasksWorkspaceModel
    @State private var editing: JiraConnection?
    @State private var adding = false

    var body: some View {
        Form {
            Section("Подключения Jira") {
                ForEach(model.connections) { connection in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(connection.name)
                            Text("\(connection.origin.host ?? "") · \(connection.email)").font(.caption).foregroundStyle(.secondary)
                            if let failure = connection.lastFailure { Text(failure).font(.caption).foregroundStyle(.orange) }
                            if connection.mentionsUnavailable { Text("Jira отклонила поиск упоминаний; зеркалятся только назначенные.").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button("Изменить") { editing = connection }
                        Button("Удалить", role: .destructive) {
                            _Concurrency.Task {
                                do { try await model.service.remove(connectionID: connection.id) } catch { model.error = TasksWorkspaceModel.describe(error) }
                                await model.refresh()
                            }
                        }
                    }.accessibilityIdentifier("tasks.settings.connection.\(connection.id.uuidString)")
                }
                Button("Добавить Jira…") { adding = true }.accessibilityIdentifier("tasks.settings.add")
                Text("Jira Cloud: почта аккаунта и API-токен (id.atlassian.com → Security → API tokens). Токен хранится только в Связке ключей.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 360)
        .sheet(item: $editing) { connection in JiraConnectionEditor(model: model, original: connection).makoshAppearance() }
        .sheet(isPresented: $adding) { JiraConnectionEditor(model: model, original: nil).makoshAppearance() }
    }
}

struct JiraConnectionEditor: View {
    @ObservedObject var model: TasksWorkspaceModel
    let original: JiraConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var origin = ""
    @State private var email = ""
    @State private var token = ""
    @State private var pollMinutes = 5
    @State private var mentions = true
    @State private var suggestWorklog = true
    @State private var checked: String?
    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "Новое подключение Jira" : "Подключение Jira").font(.headline)
            TextField("Название", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("tasks.jira.editor.name")
            TextField("Адрес сайта, https://компания.atlassian.net", text: $origin).textFieldStyle(.roundedBorder).accessibilityIdentifier("tasks.jira.editor.origin")
            TextField("Почта аккаунта", text: $email).textFieldStyle(.roundedBorder).accessibilityIdentifier("tasks.jira.editor.email")
            SecureField(original == nil ? "API-токен" : "Новый API-токен (пусто — оставить прежний)", text: $token).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tasks.jira.editor.token")
            Stepper("Опрос каждые \(pollMinutes) мин", value: $pollMinutes, in: 1...1440)
            Toggle("Искать упоминания в комментариях", isOn: $mentions)
            Toggle("Предлагать worklog при записи времени", isOn: $suggestWorklog)
            if let checked { Text(checked).font(.caption).foregroundStyle(.green) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Проверить") { _Concurrency.Task { await check() } }.disabled(busy || (token.isEmpty && original == nil)).accessibilityIdentifier("tasks.jira.editor.check")
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { _Concurrency.Task { await save() } }.keyboardShortcut(.defaultAction).disabled(busy).accessibilityIdentifier("tasks.jira.editor.save")
            }
        }
        .padding(16).frame(width: 480)
        .onAppear {
            guard let original else { return }
            name = original.name
            origin = original.origin.absoluteString
            email = original.email
            pollMinutes = Int(original.pollInterval / 60)
            mentions = original.mentions
            suggestWorklog = original.suggestWorklog
        }
    }

    private func connection() -> JiraConnection? {
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespaces)) else { return nil }
        var value = original ?? JiraConnection(name: name, origin: url, email: email)
        value.name = name
        value.origin = url
        value.email = email.trimmingCharacters(in: .whitespaces)
        value.pollInterval = TimeInterval(pollMinutes * 60)
        value.mentions = mentions
        value.suggestWorklog = suggestWorklog
        return value
    }

    private func check() async {
        guard let connection = connection() else {
            failure = "Проверьте адрес сайта."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let secret = token.isEmpty ? (try await model.service.registry.token(connectionID: connection.id) ?? "") : token
            let me = try await model.service.verify(connection, token: secret)
            checked = "Вход выполнен: \(me.displayName)"
            failure = nil
        } catch {
            checked = nil
            failure = TasksWorkspaceModel.describe(error)
        }
    }

    private func save() async {
        guard var connection = connection() else {
            failure = "Проверьте адрес сайта."
            return
        }
        busy = true
        defer { busy = false }
        if connection.accountID == nil, !token.isEmpty, let me = try? await model.service.verify(connection, token: token) { connection.accountID = me.accountID }
        do {
            try await model.service.save(connection, token: token.isEmpty ? nil : token)
            await model.refresh()
            _Concurrency.Task { await model.syncNow() }
            dismiss()
        } catch {
            failure = TasksWorkspaceModel.describe(error)
        }
    }
}

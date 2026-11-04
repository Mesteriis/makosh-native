import MakoshAI
import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var host: AIHost

    var body: some View {
        if host.configuration == nil {
            Text("Откройте рабочее пространство Макоша, чтобы настроить ИИ.").padding(24).frame(minWidth: 520)
        } else {
            AISettingsForm(model: host.settings)
        }
    }
}

struct AISettingsForm: View {
    @ObservedObject var model: AISettingsModel
    @State private var editing: AIConnection?
    @State private var adding = false

    var body: some View {
        Form {
            Section("Подключения (OpenAI-совместимый API)") {
                ForEach(model.connections) { connection in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(connection.name)
                            Text(connection.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                            if let result = model.testResult[connection.id] {
                                switch result {
                                case .success(let count): Text("Доступно моделей: \(count)").font(.caption).foregroundStyle(.green)
                                case .failure(let failure): Text(failure.message).font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        Spacer()
                        Button("Проверить") { Task { await model.test(connection.id) } }
                        Button("Изменить") { editing = connection }
                        Button("Удалить", role: .destructive) { Task { await model.remove(connection.id) } }
                    }.accessibilityIdentifier("ai.settings.connection.\(connection.id.uuidString)")
                }
                Button("Добавить подключение…") { adding = true }.accessibilityIdentifier("ai.settings.addConnection")
            }
            Section("Модели по ролям") {
                ForEach(AIRole.allCases, id: \.self) { role in
                    AIRoleRow(role: role, model: model)
                }
            }
            Section("Изображения") {
                Toggle(
                    "Сохранять изображения в S3",
                    isOn: Binding(get: { model.imagesSavedToS3 }, set: { value in Task { await model.setImagesSavedToS3(value) } }))
                Text("Выключено — изображения хранятся в зашифрованной локальной папке.").font(.caption).foregroundStyle(.secondary)
            }
            if let failure = model.failure { Text(failure.message).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 480)
        .sheet(item: $editing) { connection in AIConnectionEditor(model: model, original: connection) }
        .sheet(isPresented: $adding) { AIConnectionEditor(model: model, original: nil) }
    }
}

private struct AIRoleRow: View {
    let role: AIRole
    @ObservedObject var model: AISettingsModel
    @State private var modelName = ""

    var body: some View {
        let assignment = model.roles[role]
        HStack {
            Text(role.title).frame(width: 170, alignment: .leading)
            Picker(
                "Подключение",
                selection: Binding(
                    get: { assignment?.connectionID },
                    set: { id in
                        Task {
                            guard let id else { return await model.assign(role, connectionID: nil, model: "") }
                            // Load the model list first so a fresh role gets a real model name.
                            if model.availableModels[id] == nil { await model.test(id) }
                            let name = modelName.isEmpty ? (model.availableModels[id]?.first ?? "") : modelName
                            await model.assign(role, connectionID: id, model: name)
                        }
                    })
            ) {
                Text("Не назначено").tag(UUID?.none)
                ForEach(model.connections) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().frame(width: 170)
            if let connectionID = assignment?.connectionID ?? nil, let models = model.availableModels[connectionID], !models.isEmpty {
                Picker(
                    "Модель",
                    selection: Binding(
                        get: { assignment?.model ?? "" },
                        set: { name in Task { await model.assign(role, connectionID: connectionID, model: name) } })
                ) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            } else {
                TextField("Модель", text: $modelName).onSubmit {
                    if let id = assignment?.connectionID { Task { await model.assign(role, connectionID: id, model: modelName) } }
                }
            }
        }
        .onAppear { modelName = assignment?.model ?? "" }
        .onChange(of: assignment?.model) { _, value in modelName = value ?? "" }
        .accessibilityIdentifier("ai.settings.role.\(role.rawValue)")
    }
}

private struct AIConnectionEditor: View {
    @ObservedObject var model: AISettingsModel
    let original: AIConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var organization = ""
    @State private var project = ""
    @State private var invalid = false

    var body: some View {
        Form {
            TextField("Название", text: $name)
            TextField("Базовый URL", text: $url, prompt: Text("https://api.openai.com/v1"))
            SecureField(original == nil ? "Токен" : "Новый токен (пусто — без изменений)", text: $token)
            TextField("Организация (необязательно)", text: $organization)
            TextField("Проект (необязательно)", text: $project)
            if invalid { Text(AIFailure.invalidConnection.message).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped).frame(width: 460)
        .onAppear {
            name = original?.name ?? ""
            url = original?.baseURL.absoluteString ?? ""
            organization = original?.organization ?? ""
            project = original?.project ?? ""
        }
    }

    private func save() {
        guard let base = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
            let connection = try? AIConnection(
                id: original?.id ?? UUID(), name: name, baseURL: base, organization: organization, project: project
            ).validated()
        else {
            invalid = true
            return
        }
        // Editing keeps the stored token unless a new one is typed.
        let newToken: String? = original != nil && token.isEmpty ? nil : token
        token = ""
        Task {
            await model.save(connection, token: newToken)
            dismiss()
        }
    }
}

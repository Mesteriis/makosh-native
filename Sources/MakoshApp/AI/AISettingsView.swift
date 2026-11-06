import MakoshAI
import MakoshCore
import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var host: AIHost

    var body: some View {
        if host.configuration == nil {
            Text("Откройте рабочее пространство Макоша, чтобы настроить ИИ.").padding(24).frame(minWidth: 520)
        } else {
            VStack(spacing: 0) {
                AISettingsForm(model: host.settings)
                // Two scrolling forms share the height; keep the index status visible in a short window.
                AIIndexSection().frame(minHeight: 230)
            }
        }
    }
}

/// Which sources are open to the AI and how far indexing has got.
struct AIIndexSection: View {
    @EnvironmentObject private var host: AIHost

    var body: some View {
        Form {
            Section("Поиск по данным Макоша") {
                if host.enabledScopes.isEmpty {
                    Text("Ни один чат или ящик не открыт для ИИ. Включите «Доступно для ИИ» в настройках чата или ящика.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(host.enabledScopes, id: \.self) { scope in Text(Self.title(scope)).font(.caption) }
                }
                LabeledContent("Проиндексировано фрагментов", value: "\(host.indexStatus.indexed)")
                if host.indexStatus.pending > 0 { LabeledContent("Догружается источников", value: "\(host.indexStatus.pending)") }
                if let failure = host.indexStatus.failure, failure != .roleUnassigned(.embeddings) || !host.enabledScopes.isEmpty {
                    Text(failure.message).font(.caption).foregroundStyle(.orange)
                    if let detail = host.indexStatus.failureDetail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                }
                Toggle(
                    "Пауза индексации",
                    isOn: Binding(get: { host.indexStatus.paused }, set: { value in Task { await host.pauseIndex(value) } })
                )
                .accessibilityIdentifier("ai.settings.indexPause")
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await host.refreshIndex()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    static func title(_ scope: AIAccessScope) -> String {
        switch scope {
        case .conversation(let service, _, let conversationID): "\(service.capitalized) · чат \(conversationID.prefix(12))"
        case .mailAccount(let accountID): "Почта · ящик \(accountID.prefix(12))"
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
    @State private var contextTokens = ""
    /// Empty means the default; otherwise a whole number of at least 1 000.
    private var tokensProblem: String? {
        let text = contextTokens.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        guard let value = Int(text) else { return "Только число токенов, например 128000." }
        return value < 1_000 ? "Не меньше 1 000 токенов." : nil
    }

    var body: some View {
        let assignment = model.roles[role]
        VStack(alignment: .leading, spacing: 6) {
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
            if role == .chat, assignment != nil {
                HStack {
                    Text("Контекст модели, токенов").frame(width: 170, alignment: .leading).font(.caption).foregroundStyle(.secondary)
                    TextField("\(AITokenEstimate.defaultContextTokens)", text: $contextTokens)
                        .frame(width: 120)
                        .onSubmit {
                            guard tokensProblem == nil else { return }
                            Task { await model.setContextTokens(contextTokens.isEmpty ? nil : Int(contextTokens), role: role) }
                        }
                        .accessibilityIdentifier("ai.settings.contextTokens")
                    if let tokensProblem {
                        Text(tokensProblem).font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(
                            "бюджет беседы — \(AITokenEstimate.budget(contextTokens: assignment?.contextTokens)) токенов · Enter сохраняет"
                        ).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            modelName = assignment?.model ?? ""
            contextTokens = assignment?.contextTokens.map(String.init) ?? ""
        }
        .onChange(of: assignment?.model) { _, value in modelName = value ?? "" }
        .onChange(of: assignment?.contextTokens) { _, value in contextTokens = value.map(String.init) ?? "" }
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

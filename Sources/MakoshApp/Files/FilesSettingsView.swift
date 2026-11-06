import MakoshFiles
import SwiftUI

/// Settings → Файлы: the storages Makosh can show and send to.
struct FilesSettingsView: View {
    @EnvironmentObject private var host: FilesHost

    var body: some View {
        FilesSettingsForm(model: host.model).padding(20)
    }
}

struct FilesSettingsForm: View {
    @ObservedObject var model: FilesWorkspaceModel
    @State private var editing: PaperlessConnection?
    @State private var adding = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Хранилища") {
                ForEach(model.connections) { connection in
                    if case .paperless(let paperless) = connection {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(paperless.name)
                                Text(paperless.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                                switch model.storageStatus[paperless.id] {
                                case .success(let status)?:
                                    Text("Paperless \(status.version ?? "") · документов: \(status.documentCount)").font(.caption)
                                        .foregroundStyle(.green)
                                case .failure(let error)?: Text(error.errorDescription ?? "").font(.caption).foregroundStyle(.orange)
                                case nil: EmptyView()
                                }
                            }
                            Spacer()
                            Button("Проверить") { Task { await model.test(paperless.id) } }
                            Button("Изменить") { editing = paperless }
                            Button("Удалить", role: .destructive) {
                                Task {
                                    do { try await model.remove(paperless.id) } catch {
                                        failure = (error as? FilesFailure)?.errorDescription
                                    }
                                }
                            }
                        }.accessibilityIdentifier("files.settings.storage.\(paperless.id.uuidString)")
                    }
                }
                Button("Добавить Paperless…") { adding = true }.accessibilityIdentifier("files.settings.addStorage")
                Text("Токен API создаётся в Paperless (профиль → API token) и хранится только в Связке ключей.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 360)
        .sheet(item: $editing) { connection in FileStorageEditor(model: model, original: connection) }
        .sheet(isPresented: $adding) { FileStorageEditor(model: model, original: nil) }
    }
}

/// Name, address and token; defaults for uploads once the token works.
struct FileStorageEditor: View {
    @ObservedObject var model: FilesWorkspaceModel
    let original: PaperlessConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var documentType: Int?
    @State private var tags: Set<Int> = []
    @State private var lists: PaperlessLists?
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        Form {
            TextField("Название", text: $name).accessibilityIdentifier("files.storage.editor.name")
            TextField("Адрес", text: $url, prompt: Text("https://doc.example.org")).accessibilityIdentifier("files.storage.editor.url")
            SecureField(original == nil ? "Токен API" : "Новый токен (пусто — без изменений)", text: $token)
                .accessibilityIdentifier("files.storage.editor.token")
            if let lists {
                Section("По умолчанию при отправке") {
                    Picker("Тип документа", selection: $documentType) {
                        Text("Не задан").tag(Int?.none)
                        ForEach(lists.types) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    ForEach(lists.tags) { tag in
                        Toggle(
                            tag.name,
                            isOn: Binding(
                                get: { tags.contains(tag.id) }, set: { if $0 { tags.insert(tag.id) } else { tags.remove(tag.id) } }))
                    }
                }
            } else if original != nil {
                Text("Типы документов и теги загрузятся после проверки подключения.").font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
            HStack {
                if let original {
                    Button("Загрузить справочники") { Task { lists = await model.lists(for: original.id) } }
                }
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction).disabled(saving)
                    .accessibilityIdentifier("files.storage.editor.save")
            }
        }
        .formStyle(.grouped).frame(width: 480)
        .onAppear {
            name = original?.name ?? "Paperless"
            url = original?.baseURL.absoluteString ?? ""
            documentType = original?.defaultDocumentType
            tags = Set(original?.defaultTags ?? [])
            if let original { lists = model.lists[original.id] }
        }
    }

    private func save() {
        guard let base = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            failure = FilesFailure.invalidConnection.errorDescription
            return
        }
        let connection = PaperlessConnection(
            id: original?.id ?? UUID(), name: name, baseURL: base, defaultDocumentType: documentType, defaultTags: tags.sorted())
        // Editing keeps the stored token unless a new one is typed.
        let newToken: String? = original != nil && token.isEmpty ? nil : token
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.save(.paperless(connection), token: newToken)
                token = ""
                dismiss()
            } catch {
                failure = (error as? FilesFailure)?.errorDescription ?? "Не удалось сохранить подключение."
            }
        }
    }
}

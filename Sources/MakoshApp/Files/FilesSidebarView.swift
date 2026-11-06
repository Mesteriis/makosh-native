import MakoshFiles
import SwiftUI

/// Sources on top, storages below; the "+" opens the storage editor.
struct FilesSidebarView: View {
    @ObservedObject var model: FilesWorkspaceModel
    @ObservedObject var host: FilesHost
    @State private var adding = false
    static let services: [(id: String, title: String, symbol: String)] = [
        ("mail", "Почта", "envelope"), ("telegram", "Telegram", "paperplane"), ("whatsapp", "WhatsApp", "message"),
        ("teams", "Teams", "person.3"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Файлы").font(.title2.bold())
                    Text("\(model.items.count) в архиве").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            List(selection: Binding(get: { Optional(model.source) }, set: { if let value = $0 { model.source = value } })) {
                Section {
                    Label("Все файлы", systemImage: "folder").tag(FilesSource.all).accessibilityIdentifier("files.source.all")
                    ForEach(Self.services, id: \.id) { service in
                        Label(service.title, systemImage: service.symbol).tag(FilesSource.service(service.id))
                            .accessibilityIdentifier("files.source.\(service.id)")
                    }
                }
                Section {
                    if model.connections.isEmpty {
                        Text("Подключите Paperless, чтобы отправлять туда счета и документы.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.connections) { connection in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(connection.name, systemImage: "archivebox")
                            Text(status(connection.id)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(FilesSource.storage(connection.id)).accessibilityIdentifier("files.storage.\(connection.id.uuidString)")
                    }
                } header: {
                    HStack {
                        Text("Хранилища")
                        Spacer()
                        Button {
                            adding = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless).help("Добавить хранилище").accessibilityIdentifier("files.storage.add")
                    }
                }
            }.listStyle(.inset).scrollContentBackground(.hidden)
        }.frame(maxHeight: .infinity, alignment: .top)
            .sheet(isPresented: $adding) { FileStorageEditor(model: model, original: nil).makoshAppearance() }
    }

    private func status(_ id: UUID) -> String {
        switch model.storageStatus[id] {
        case .success(let status)?: "Paperless · \(status.documentCount) документов"
        case .failure(let failure)?: failure.errorDescription ?? "Недоступно"
        case nil: "Paperless"
        }
    }
}

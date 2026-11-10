import MakoshFiles
import SwiftUI

/// Sources on top, storages below; the "+" opens the storage editor.
struct FilesSidebarView: View {
    @ObservedObject var model: FilesWorkspaceModel
    @ObservedObject var host: FilesHost
    @State private var adding = false
    @FocusState private var focusedSource: FilesSource?
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
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    source(.all) { Label("Все файлы", systemImage: "folder") }
                        .accessibilityIdentifier("files.source.all")
                    ForEach(Self.services, id: \.id) { service in
                        source(.service(service.id)) { Label(service.title, systemImage: service.symbol) }
                            .accessibilityIdentifier("files.source.\(service.id)")
                    }
                    HStack {
                        Text("Хранилища").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            adding = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain).help("Добавить хранилище")
                        .accessibilityIdentifier("files.storage.add")
                    }.padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 8)
                    if model.connections.isEmpty {
                        Text("Подключите Paperless, чтобы отправлять туда счета и документы.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                    ForEach(model.connections) { connection in
                        source(.storage(connection.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(connection.name, systemImage: "archivebox")
                                Text(status(connection.id)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.accessibilityIdentifier("files.storage.\(connection.id.uuidString)")
                    }
                }.padding(.horizontal, 10).padding(.bottom, 10)
            }

        }.frame(maxHeight: .infinity, alignment: .top)
            .sheet(isPresented: $adding) { FileStorageEditor(model: model, original: nil).makoshAppearance() }
    }

    private var sources: [FilesSource] {
        [.all] + Self.services.map { .service($0.id) } + model.connections.map { .storage($0.id) }
    }

    private func moveSource(from item: FilesSource, by offset: Int) {
        guard let index = sources.firstIndex(of: item), sources.indices.contains(index + offset) else { return }
        let next = sources[index + offset]
        model.source = next
        focusedSource = next
    }

    private func source<Content: View>(_ item: FilesSource, @ViewBuilder content: () -> Content) -> some View {
        Button {
            model.source = item
            focusedSource = item
        } label: {
            content().symbolRenderingMode(.monochrome)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .foregroundStyle(model.source == item ? WorkspaceStyle.accent : .primary)
                .background(
                    model.source == item ? WorkspaceStyle.accent.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
        }.buttonStyle(.plain)
            .focusable()
            .focused($focusedSource, equals: item)
            .accessibilityAddTraits(model.source == item ? .isSelected : [])
            .onKeyPress(.upArrow) {
                moveSource(from: item, by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSource(from: item, by: 1)
                return .handled
            }
    }

    private func status(_ id: UUID) -> String {
        switch model.storageStatus[id] {
        case .success(let status)?: "Paperless · \(status.documentCount) документов"
        case .failure(let failure)?: failure.errorDescription ?? "Недоступно"
        case nil: "Paperless"
        }
    }
}

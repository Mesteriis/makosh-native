import AppKit
import MakoshAI
import MakoshFiles
import SwiftUI

/// The documents of one Paperless connection: live search, pages, preview, download.
struct PaperlessDocumentsView: View {
    @ObservedObject var model: FilesWorkspaceModel
    let connectionID: UUID
    @State private var query = ""
    @State private var selection = Set<Int>()
    @State private var preview: FilePreviewLease?
    @State private var busy = false
    @State private var failure: String?
    @Environment(\.filesHost) private var host

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Поиск в Paperless", text: $query).textFieldStyle(WorkspaceTextFieldStyle())
                    .onSubmit { Task { await model.searchDocuments(query) } }.accessibilityIdentifier("files.paperless.search")
                Button("Найти") { Task { await model.searchDocuments(query) } }.accessibilityIdentifier("files.paperless.find")
                if model.loadingDocuments || busy { ProgressView().controlSize(.small) }
            }.padding(16)
            Divider()
            if model.documents.isEmpty, let error = model.error {
                ContentUnavailableView {
                    Label("Paperless недоступен", systemImage: "archivebox")
                } description: {
                    Text(error)
                } actions: {
                    Button("Повторить") { Task { await model.searchDocuments(model.documentQuery) } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.documents.isEmpty, !model.loadingDocuments {
                ContentUnavailableView(
                    "Документов нет", systemImage: "archivebox", description: Text("По этому запросу в Paperless ничего не найдено.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
                if model.hasMoreDocuments {
                    Divider()
                    Button("Ещё") { Task { await model.loadMoreDocuments() } }.disabled(model.loadingDocuments).padding(8)
                        .accessibilityIdentifier("files.paperless.more")
                }
            }
            if let failure {
                Divider()
                HStack {
                    Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button("Скрыть") { self.failure = nil }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .task(id: connectionID) {
            query = ""
            if model.lists[connectionID] == nil { _ = await model.lists(for: connectionID) }
        }
        .sheet(item: $preview) { lease in FilePreviewView(lease: lease, caption: "Оригинал документа из Paperless").makoshAppearance() }
    }

    private var table: some View {
        Table(model.documents, selection: $selection) {
            TableColumn("Название") { document in Text(document.title).lineLimit(1).help(document.title) }
            TableColumn("Дата") { document in
                Text(document.created.map { $0.formatted(.dateTime.day().month().year()) } ?? "—").monospacedDigit()
            }.width(min: 90, ideal: 110)
            TableColumn("Тип") { document in Text(typeName(document.documentType)).lineLimit(1) }.width(min: 100, ideal: 150)
            TableColumn("Теги") { document in Text(tagNames(document.tags)).lineLimit(1) }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if ids.count == 1, let document = model.documents.first(where: { ids.contains($0.id) }) { menu(document) }
        } primaryAction: { ids in
            if ids.count == 1, let document = model.documents.first(where: { ids.contains($0.id) }) { show(document) }
        }
        .accessibilityIdentifier("files.paperless.table")
    }

    @ViewBuilder private func menu(_ document: PaperlessDocument) -> some View {
        Button("Посмотреть") { show(document) }.disabled(busy)
        Button("Сохранить как…") { save(document) }.disabled(busy)
        Button("Открыть в Paperless") {
            if let url = model.documentURL(id: document.id, in: connectionID) { NSWorkspace.shared.open(url) }
        }
        if let host {
            Divider()
            FileActionsMenu(
                handoff: { host.handoff(connectionID: connectionID, document: document) },
                source: .paperless(connectionID: connectionID, documentID: document.id))
        }
    }

    private func typeName(_ id: Int?) -> String {
        guard let id else { return "—" }
        return model.lists[connectionID]?.types.first { $0.id == id }?.name ?? "#\(id)"
    }

    private func tagNames(_ ids: [Int]) -> String {
        ids.map { id in model.lists[connectionID]?.tags.first { $0.id == id }?.name ?? "#\(id)" }.joined(separator: ", ")
    }

    private func fileName(_ document: PaperlessDocument) -> String {
        document.originalFileName.map { URL(fileURLWithPath: $0).lastPathComponent } ?? (document.title + ".pdf")
    }

    private func show(_ document: PaperlessDocument) {
        guard !busy else { return }
        busy = true
        let model = model, id = connectionID
        Task {
            defer { busy = false }
            do {
                preview = try await FilePreviewLease.create(name: fileName(document)) { url in
                    try await model.download(documentID: document.id, from: id, to: url)
                }
            } catch { failure = Self.describe(error) }
        }
    }

    private func save(_ document: PaperlessDocument) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(document)
        panel.title = "Сохранить документ из Paperless"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            busy = true
            Task {
                defer { busy = false }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "makosh-paperless-save-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                do {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    let staged = directory.appendingPathComponent("file")
                    try await model.download(documentID: document.id, from: connectionID, to: staged)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                    } else {
                        try FileManager.default.moveItem(at: staged, to: destination)
                    }
                } catch { failure = Self.describe(error) }
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? FilesFailure)?.errorDescription ?? (error as? LocalizedError)?.errorDescription
            ?? "Не удалось получить документ из Paperless."
    }
}

import MakoshFiles
import SwiftUI

/// "Из Файлов…" for a composer: a file of the archive or Paperless, staged as
/// a private copy and handed over like a file picked from disk.
struct FilePickerSheet: View {
    let onPick: ([URL]) -> Void
    @Environment(\.filesHost) private var files
    @Environment(\.dismiss) private var dismiss
    @State private var search: FilePickerSearch?
    @State private var query = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Из Файлов").font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            TextField("Имя файла или документ Paperless", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier(
                "files.picker.search")
            if let search {
                FilePickerList(search: search, busy: busy, choose: choose)
            } else {
                ContentUnavailableView("Файлы недоступны", systemImage: "folder", description: Text("Раздел «Файлы» ещё не открыт."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(16).frame(width: 480)
        .onAppear {
            guard search == nil, let files else { return }
            let model = files.model
            let value = FilePickerSearch(
                catalogue: { model.items },
                paperless: { connectionID, query in
                    guard let client = await model.client(for: connectionID) else { return [] }
                    return try await client.documents(query: query, page: 1).items
                }, connections: { model.connections.map(\.id) })
            value.update(query: "")
            search = value
            if model.items.isEmpty {
                Task {
                    await model.refresh()
                    value.update(query: query)
                }
            }
        }
        .onChange(of: query) { _, value in search?.update(query: value) }
    }

    private func choose(_ pick: FilePick) {
        guard !busy, let files else { return }
        busy = true
        let handoff: FileHandoff
        switch pick.kind {
        case .archive(let item): handoff = files.handoff(item)
        case .paperless(let connectionID, let document): handoff = files.handoff(connectionID: connectionID, document: document)
        }
        Task {
            do {
                let staged = try await files.stage.stage(handoff)
                onPick([staged.url])
                dismiss()
            } catch {
                failure =
                    (error as? FilesFailure)?.errorDescription ?? (error as? LocalizedError)?.errorDescription
                    ?? "Не удалось подготовить файл."
                busy = false
            }
        }
    }
}

private struct FilePickerList: View {
    @ObservedObject var search: FilePickerSearch
    let busy: Bool
    let choose: (FilePick) -> Void

    var body: some View {
        if search.results.isEmpty {
            ContentUnavailableView("Ничего не найдено", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, minHeight: 200)
        } else {
            List(search.results) { pick in
                Button {
                    choose(pick)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pick.title).lineLimit(1)
                        Text(pick.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain).disabled(busy).accessibilityIdentifier("files.picker.item.\(pick.id)")
            }.listStyle(.plain).frame(minHeight: 260)
        }
        if let failure = search.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
    }
}

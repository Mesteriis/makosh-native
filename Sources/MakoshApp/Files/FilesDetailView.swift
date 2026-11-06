import AppKit
import MakoshCore
import MakoshFiles
import SwiftUI

/// The catalogue of retained files, or the selected storage.
struct FilesDetailView: View {
    @ObservedObject var model: FilesWorkspaceModel
    @ObservedObject var host: FilesHost
    /// Opens the chat or section a file came from.
    var openSource: (MessageArchiveIdentity) -> Void = { _ in }
    @State private var selection = Set<UUID>()
    @State private var preview: FilePreviewLease?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            if case .storage(let id) = model.source {
                PaperlessDocumentsView(model: model, connectionID: id)
            } else if model.items.isEmpty, model.loading {
                ContentUnavailableView(
                    "Читаем архив…", systemImage: "folder", description: Text("Первое заполнение большого архива занимает время.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "Файлов пока нет", systemImage: "folder",
                    description: Text(
                        host.configured ? "Вложения из писем и чатов появятся здесь, как только попадут в архив." : "Архив ещё не открыт.")
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visible.isEmpty {
                ContentUnavailableView.search(text: model.search).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
            if let message = model.error ?? failure {
                Divider()
                HStack {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button("Скрыть") {
                        model.error = nil
                        failure = nil
                    }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.vertical, 8).accessibilityIdentifier("files.error")
            }
        }
        .task {
            await model.refresh()
            model.startPolling()
            if let highlighted = model.highlighted { selection = [highlighted] }
        }
        .onChange(of: model.highlighted) { _, value in if let value { selection = [value] } }
        .onDisappear(perform: model.stopPolling)
        .sheet(item: $preview) { lease in FilePreviewView(lease: lease).makoshAppearance() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Поиск по имени, чату, отправителю", text: $model.search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("files.search")
            Picker("Тип", selection: $model.category) {
                Text("Все типы").tag(FileCategory?.none)
                ForEach(FileCategory.allCases, id: \.self) { Text($0.title).tag(FileCategory?.some($0)) }
            }.frame(width: 150).accessibilityIdentifier("files.category")
            Picker("Порядок", selection: $model.sort) {
                Text("Сначала новые").tag(FilesSort.dateDescending)
                Text("По имени").tag(FilesSort.name)
            }.frame(width: 150).accessibilityIdentifier("files.sort")
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }.help("Обновить").disabled(model.loading).accessibilityIdentifier("files.refresh")
            if model.loading || busy { ProgressView().controlSize(.small) }
        }
    }

    private var table: some View {
        Table(model.visible, selection: $selection) {
            TableColumn("Имя") { item in
                Label(item.name, systemImage: Self.symbol(item.category)).lineLimit(1).help(item.name)
            }
            TableColumn("Откуда") { item in
                Text(item.sourceTitle ?? Self.serviceTitle(item.service)).lineLimit(1).foregroundStyle(
                    item.sourceTitle == nil ? .secondary : .primary)
            }
            TableColumn("Размер") { item in
                Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)).monospacedDigit()
            }.width(min: 70, ideal: 90)
            TableColumn("Дата") { item in
                Text(item.date, format: .dateTime.day().month().year().hour().minute()).monospacedDigit()
            }.width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let item = ids.count == 1 ? model.visible.first(where: { ids.contains($0.id) }) : nil { menu(item) }
        } primaryAction: { ids in
            if let item = ids.count == 1 ? model.visible.first(where: { ids.contains($0.id) }) : nil { show(item) }
        }
        .accessibilityIdentifier("files.table")
    }

    @ViewBuilder private func menu(_ item: FileCatalogueItem) -> some View {
        Button("Посмотреть") { show(item) }.disabled(busy)
        Button("Сохранить как…") { save(item) }.disabled(busy)
        Button("Открыть источник") { openSource(item.identity) }
        Divider()
        FileSendMenu(handoff: { host.handoff(item) })
    }

    private func show(_ item: FileCatalogueItem) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { preview = try await host.preview(item) } catch { failure = Self.describe(error) }
        }
    }

    private func save(_ item: FileCatalogueItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: item.name).lastPathComponent
        panel.title = "Сохранить файл из архива"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            busy = true
            Task {
                defer { busy = false }
                do { try await host.export(item, to: url) } catch { failure = Self.describe(error) }
            }
        }
    }

    static func symbol(_ category: FileCategory) -> String {
        switch category {
        case .document: "doc.text"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "shippingbox"
        case .other: "doc"
        }
    }

    static func serviceTitle(_ service: String) -> String {
        FilesSidebarView.services.first { $0.id == service }?.title ?? service
    }

    private static func describe(_ error: Error) -> String {
        (error as? FilesFailure)?.errorDescription ?? (error as? LocalizedError)?.errorDescription ?? "Не удалось получить файл из архива."
    }
}

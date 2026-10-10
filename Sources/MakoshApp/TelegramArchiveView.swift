import SwiftUI
import MakoshCore
import MakoshTelegram
import AppKit

struct TelegramArchiveButton: View {
    @ObservedObject var archive: TelegramArchiveController
    @ObservedObject private var files: TelegramFileArchiveController
    @State private var showingArchive = false

    init(archive: TelegramArchiveController) {
        self.archive = archive
        self.files = archive.files
    }
    private var hasError: Bool { archive.error != nil || files.error != nil }
    private var busy: Bool { archive.isArchiving || files.isBusy }
    private var status: String {
        if hasError && busy { return "Есть ошибка; запись продолжается" }
        if hasError { return "Есть ошибка; откройте архив для подробностей и повтора" }
        if busy { return "Выполняется запись в архив" }
        return "Доступен без подключения к Telegram"
    }
    var body: some View {
        Button { showingArchive = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.doc")
                if hasError { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                if busy { ProgressView().controlSize(.mini) }
            }.frame(minWidth: 28, minHeight: 28)
        }.buttonStyle(.plain)
            .help("Локальный архив · " + status)
            .accessibilityLabel(hasError ? "Локальный архив, есть ошибка" : busy ? "Локальный архив, запись" : "Локальный архив")
            .accessibilityValue(status)
            .accessibilityIdentifier("telegram.archive.open")
            .sheet(isPresented: $showingArchive) { TelegramArchiveView(archive: archive) }
    }
}

private struct TelegramArchiveView: View {
    @ObservedObject var archive: TelegramArchiveController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Локальный архив сообщений", systemImage: "lock.doc").font(.title2.bold())
                Spacer()
                Button("Обновить", action: archive.reload).disabled(archive.isLoading)
                    .accessibilityIdentifier("telegram.archive.refresh")
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("telegram.archive.close")
            }
            Text("Сохранённые снимки остаются здесь при правках и удалениях в Telegram. Архив доступен без подключения к Telegram.")
                .font(.callout).foregroundStyle(.secondary)
            if archive.isSynthetic {
                Text(archive.usesSyntheticS3 ? "СИНТЕТИЧЕСКИЙ АРХИВ • изолированные PostgreSQL/S3, личные аккаунты и Связка ключей не используются" : "СИНТЕТИЧЕСКИЙ АРХИВ • данные в памяти, личные аккаунты и PostgreSQL не используются")
                    .font(.caption.bold()).foregroundStyle(.secondary)
            }
            Text("Полностью загруженные файлы сохраняются зашифрованными в S3; PostgreSQL хранит только сведения и ссылки. Превью и ещё не загруженные файлы остаются сведениями о вложениях.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(archive.status).font(.caption).foregroundStyle(.secondary)
                    if archive.isArchiving { ProgressView().controlSize(.mini) }
                    Spacer()
                }
                if let error = archive.error {
                    HStack(alignment: .top) {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        Button("Повторить запись", action: archive.retry).controlSize(.small)
                            .accessibilityIdentifier("telegram.archive.retry")
                    }
                }
                TelegramFileArchiveStatus(files: archive.files)
            }
            Divider()
            if archive.isLoading && archive.records.isEmpty {
                ProgressView("Открытие зашифрованного архива…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if archive.records.isEmpty {
                ContentUnavailableView("Нет сохранённых снимков", systemImage: "text.page", description: Text("Здесь появятся сообщения, записанные в локальный архив после получения Макошем."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(archive.records) { record in archiveRow(record) }
                    }.padding(4)
                }.accessibilityIdentifier("telegram.archive.records")
            }
            HStack {
                Text("Снимков в этом окне: \(archive.records.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if archive.canLoadMore {
                    Button("Более ранние снимки", action: archive.loadOlder).disabled(archive.isLoading)
                        .accessibilityIdentifier("telegram.archive.older")
                }
            }
        }.padding(24).frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 620)
            .onAppear(perform: archive.reload)
    }
    private func archiveRow(_ record: MessageArchiveRecord) -> some View {
        let observation = record.observation, identity = observation.identity
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(identity.service) · аккаунт \(identity.accountID) · диалог \(identity.conversationID)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("#\(record.sequence)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            switch observation.event {
            case let .message(content):
                HStack {
                    Text(content.author).font(.caption.bold())
                    if content.isOutgoing { Text("Исходящее").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(content.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text(content.text.isEmpty ? "Сообщение с вложением" : content.text).textSelection(.enabled)
                if let editedAt = content.editedAt {
                    Text("Время правки источника: \(editedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(content.attachments.enumerated()), id: \.offset) { _, attachment in
                    TelegramArchivedAttachment(files: archive.files,identity: identity,attachment: attachment,synthetic: archive.isSynthetic && !archive.usesSyntheticS3)
                }
            case .deleted:
                Label("Удалено в Telegram. Сохранённые версии остаются в архиве.", systemImage: "archivebox")
            case .removedFromSource:
                Label("Убрано из кеша Telegram; причина неизвестна. Сохранённые версии остаются в архиве.", systemImage: "archivebox")
            }
            Text("Получено Макошем: \(observation.observedAt.formatted(date: .abbreviated, time: .shortened)) · сообщение \(identity.messageID)")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
        }.accessibilityIdentifier("telegram.archive.record.\(record.sequence)")
    }
}

private struct TelegramFileArchiveStatus: View {
    @ObservedObject var files: TelegramFileArchiveController
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack {
                Label(files.status,systemImage: "externaldrive.badge.icloud").font(.caption).foregroundStyle(.secondary)
                if files.isBusy { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Проверить очередь файлов",action: files.retry).controlSize(.small).disabled(files.isBusy)
                    .accessibilityIdentifier("telegram.archive.files.retry")
            }
            if let error = files.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct TelegramArchivedAttachment: View {
    @ObservedObject var files: TelegramFileArchiveController
    let identity: MessageArchiveIdentity
    let attachment: MessageArchiveAttachment
    let synthetic: Bool
    @State private var record: ArchiveFileRecord?
    @State private var checked = false
    @StateObject private var actions = TelegramAttachmentActions()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading,spacing: 4) {
            HStack {
                Label(attachment.name,systemImage: "paperclip")
                if let record {
                    Text("Копия в S3").foregroundStyle(.secondary)
                    Button("Посмотреть") { actions.previewArchived(files: files, record: record) }.disabled(actions.isBusy)
                        .accessibilityIdentifier("telegram.archive.file.preview.\(attachment.id)")
                    Button("Сохранить из архива…") { actions.saveArchived(files: files,record: record) }.disabled(actions.isBusy)
                        .accessibilityIdentifier("telegram.archive.file.export.\(attachment.id)")
                } else { Text(checked || synthetic ? "Копия файла в S3 не найдена" : "Проверка копии…").foregroundStyle(.secondary) }
                if actions.isBusy { ProgressView().controlSize(.mini) }
                if actions.saved { Text("Сохранено").foregroundStyle(.secondary) }
            }.font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let error = actions.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.sheet(item: $actions.archivedPreview) { preview in
            TelegramArchivedFilePreviewView(preview: preview)
        }.onDisappear(perform: actions.cancel)
        .task(id: files.revision) {
            guard !synthetic else { return }
            do { record = try await files.file(identity: identity,attachmentID: attachment.id); checked = true; error = nil }
            catch { checked = true; self.error = "Не удалось проверить копию файла в архиве." }
        }
    }
}

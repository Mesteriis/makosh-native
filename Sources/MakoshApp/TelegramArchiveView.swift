import SwiftUI
import MakoshCore
import MakoshTelegram

struct TelegramArchiveBar: View {
    @ObservedObject var archive: TelegramArchiveController
    @State private var showingArchive = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.doc")
                Text(archive.status).font(.caption).foregroundStyle(.secondary)
                if archive.isArchiving { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Локальный архив") { showingArchive = true }
                    .accessibilityIdentifier("telegram.archive.open")
            }
            if let error = archive.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Повторить запись", action: archive.retry).controlSize(.small)
                        .accessibilityIdentifier("telegram.archive.retry")
                }
            }
        }.padding(12)
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
                Text("СИНТЕТИЧЕСКИЙ АРХИВ • данные в памяти, личные аккаунты и PostgreSQL не используются")
                    .font(.caption.bold()).foregroundStyle(.secondary)
            }
            Text("Пока сохраняются текст и сведения о вложениях. Постоянное сохранение самих файлов ещё не подключено.")
                .font(.caption).foregroundStyle(.secondary)
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
            if let error = archive.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
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
                    Label("\(attachment.name) · сведения о вложении, файл ещё не в архиве", systemImage: "paperclip")
                        .font(.caption).foregroundStyle(.secondary)
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

import SwiftUI
import MakoshTelegram

struct TelegramDownloadsView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var media: TelegramMediaController
    @ObservedObject private var settings: TelegramAutoDownloadSettings
    @StateObject private var actions = TelegramAttachmentActions()
    @State private var limit = 100
    @State private var showCache = false
    @Environment(\.dismiss) private var dismiss
    init(model: TelegramModel) { self.model = model; media = model.media; settings = model.autoDownloadSettings }
    var body: some View {
        let transfers = media.transfers
        VStack(spacing:0) {
            HStack { Text("Загрузки").font(.headline); Spacer(); Button("Готово") { dismiss() } }.padding()
            Form {
                Section {
                    HStack {
                        Text(model.automaticDownloadsPaused ? "Автозагрузка приостановлена" : settings.preferences.enabled ? "Правило автозагрузки включено" : "Автозагрузка выключена").font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("telegram.downloads.auto.status")
                        Spacer()
                        let context = settings.contextID
                        Button(model.automaticDownloadsPaused ? "Продолжить автозагрузку" : "Приостановить автозагрузку") {
                            _ = model.setAutomaticDownloadsPaused(!model.automaticDownloadsPaused,contextID:context)
                        }.disabled(settings.accountID == nil || settings.error != nil).accessibilityIdentifier("telegram.downloads.auto.pause")
                    }
                    Text("Загрузки файлов текущего чата. Пока это окно открыто, автозагрузка переписки временно остановлена; ручные передачи продолжаются.").font(.caption).foregroundStyle(.secondary)
                }
                if transfers.isEmpty { Section { Text("Нет загрузок в текущем чате").accessibilityIdentifier("telegram.downloads.empty") } }
                ForEach(Array(transfers.prefix(limit))) { transfer in
                    Section {
                        VStack(alignment:.leading,spacing:8) {
                            HStack { Image(systemName:transfer.attachment.kind == .photo ? "photo" : "doc"); Text(transfer.attachment.name).lineLimit(2); Spacer() }
                            HStack {
                                Text(transfer.automatic ? "Автозагрузка" : "Ручная загрузка").font(.caption).foregroundStyle(.secondary)
                                if let bytes = transfer.attachment.byteCount { Text(telegramByteCount(bytes)).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                controls(transfer)
                            }
                            if case let .downloading(progress) = transfer.phase {
                                if let progress { ProgressView(value:progress).accessibilityLabel("Загружено \(Int(progress * 100)) процентов") }
                                else { ProgressView().progressViewStyle(.linear) }
                            }
                        }
                    }.accessibilityIdentifier("telegram.downloads.item.\(transfer.id)")
                }
                if transfers.count > limit { Button("Показать ещё загрузки") { limit += 100 } }
                Section {
                    let context = media.transferContextID
                    Button("Убрать завершённые из списка") { _ = media.clearFinishedTransfers(contextID:context) }
                        .disabled(actions.isBusy || !transfers.contains { if case .downloading = $0.phase { return false }; return true })
                        .accessibilityIdentifier("telegram.downloads.clearFinished")
                    Button("Использование памяти…") { showCache = true }.accessibilityIdentifier("telegram.downloads.cache")
                }
                if actions.isBusy { ProgressView("Сохранение файла…") }
                if let error = actions.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("telegram.downloads.exportError") }
                if actions.saved { Text("Файл сохранён.").foregroundStyle(.secondary).accessibilityIdentifier("telegram.downloads.saved") }
            }.formStyle(.grouped)
        }.frame(width:600,height:620)
            .onDisappear { actions.cancel() }
            .sheet(isPresented:$showCache) { TelegramCacheSettingsView(controller:model.cache,maintenance:model.cacheMaintenance) }
    }
    @ViewBuilder private func controls(_ transfer: TelegramMediaTransfer) -> some View {
        switch transfer.phase {
        case .downloading:
            Button("Отменить") { _ = media.cancelTransfer(transfer) }.accessibilityIdentifier("telegram.downloads.cancel.\(transfer.id)")
        case .ready:
            Text("Загружен").font(.caption).foregroundStyle(.secondary)
            Button("Сохранить…") { actions.save(media:media,key:transfer.key,name:transfer.attachment.name,transfer:transfer) }
                .disabled(actions.isBusy).accessibilityIdentifier("telegram.downloads.save.\(transfer.id)")
        case .failed, .timedOut, .cancelled:
            Text(transfer.phase == .cancelled ? "Отменено" : transfer.phase == .timedOut ? "Время загрузки истекло" : "Ошибка загрузки").font(.caption).foregroundStyle(.secondary)
            Button("Повторить") { _ = media.retryTransfer(transfer) }.accessibilityIdentifier("telegram.downloads.retry.\(transfer.id)")
        case .idle: Text("Ожидание").font(.caption)
        }
    }
}

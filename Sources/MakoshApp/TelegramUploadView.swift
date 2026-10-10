import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MakoshTelegram

@MainActor
private enum TelegramUploadPanel {
    static func choose(mode: TelegramUploadMode) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = mode == .photo ? "Выберите фотографию" : "Выберите файл"
        if mode == .photo { panel.allowedContentTypes = [.image] }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
}

struct TelegramAttachButtons: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var upload: TelegramUploadController
    @State private var choosing = false
    init(model: TelegramModel) { self.model = model; upload = model.upload }
    var body: some View {
        HStack(spacing: 8) {
            Button { choose(.file) } label: { Image(systemName: "paperclip") }
                .help("Прикрепить файл без изменения оригинала").accessibilityLabel("Прикрепить файл")
                .accessibilityIdentifier("telegram.upload.chooseFile")
            Button { choose(.photo) } label: { Image(systemName: "photo") }
                .help("Подготовить фотографию для отправки").accessibilityLabel("Прикрепить фото")
                .accessibilityIdentifier("telegram.upload.choosePhoto")
        }.disabled(choosing || model.uploadTarget == nil || upload.phase != .idle)
    }
    private func choose(_ mode: TelegramUploadMode) {
        guard !choosing, let target = model.uploadTarget else { return }
        let caption = model.draft
        let contextID = model.uploadContextID
        choosing = true
        Task { @MainActor in
            defer { choosing = false }
            guard let source = await TelegramUploadPanel.choose(mode: mode) else { return }
            model.prepareUpload(source: source, mode: mode, target: target, caption: caption, contextID: contextID)
        }
    }
}

struct TelegramUploadView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var upload: TelegramUploadController
    init(model: TelegramModel) { self.model = model; upload = model.upload }
    var body: some View {
        if upload.phase != .idle || upload.error != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let target = upload.target {
                    HStack {
                        Label("Получатель: \(target.title)", systemImage: "paperplane")
                        Spacer()
                        if target.chatID != model.selectedChatID {
                            Button("Открыть диалог") { model.selectedChatID = target.chatID }
                                .accessibilityIdentifier("telegram.upload.openRecipient")
                        }
                    }
                }
                if let file = upload.file {
                    Text("\(file.name) • \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                        .font(.callout).accessibilityIdentifier("telegram.upload.file")
                    if file.mode == .photo {
                        Text("Фото будет отправлено как JPEG размером не более 2560 пикселей без исходных метаданных.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if upload.phase == .ready {
                    TextField("Подпись к вложению", text: $upload.caption, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("telegram.upload.caption")
                    Text("Подпись: \(upload.caption.utf16.count)/1024. Проверьте получателя перед отправкой.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if upload.phase == .preparing || upload.phase == .storing || upload.phase == .enqueuing {
                        ProgressView().controlSize(.small)
                    }
                    Text(status).font(.callout).accessibilityIdentifier("telegram.upload.status")
                    Spacer()
                    if upload.phase == .ready {
                        Button(model.isSyntheticPreview ? "Имитировать очередь" : "Отправить вложение") { upload.send() }
                            .buttonStyle(.borderedProminent).disabled(!upload.canSend)
                            .accessibilityIdentifier("telegram.upload.send")
                    }
                    if upload.canCancel {
                        Button("Отменить подготовку", action: upload.cancelPreparation)
                            .accessibilityIdentifier("telegram.upload.cancel")
                    } else if upload.phase != .enqueuing {
                        Button(upload.messageID != nil || upload.phase == .uncertain ? "Закрыть наблюдение" : "Закрыть", action: upload.clear)
                            .accessibilityIdentifier("telegram.upload.clear")
                    }
                }
                if let error = upload.error { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("telegram.upload.error") }
            }.padding(16).background(Color.accentColor.opacity(0.06))
        }
    }
    private var status: String {
        switch upload.phase {
        case .idle: "Подготовка завершена."
        case .preparing: "Подготовка копии вложения…"
        case .ready: "Вложение готово к отправке."
        case .storing: "Сохранение вложения в кэше Telegram…"
        case .enqueuing: "Постановка в локальную очередь…"
        case .queued(let progress):
            model.isSyntheticPreview ? "Синтетическая очередь: отправки в Telegram нет." :
                progress.map { "В локальной очереди • \(Int($0 * 100))%. Доставка не подтверждена." } ?? "В локальной очереди. Доставка не подтверждена."
        case .queueFailed: "Telegram сообщил об ошибке очереди. Автоматический повтор не выполняется."
        case .rejected: "Вложение не поставлено в очередь."
        case .uncertain: "Результат пока неизвестен. Не отправляйте вложение повторно."
        case .cancelled: "Подготовка отменена."
        case .failed: "Не удалось подготовить вложение."
        }
    }
}

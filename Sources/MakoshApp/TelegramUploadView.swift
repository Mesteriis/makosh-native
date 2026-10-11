import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MakoshTelegram

@MainActor
private enum TelegramUploadPanel {
    static func choose(mode: TelegramUploadMode) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = mode == .photo ? "Выберите фотографию" : "Выберите файл"
        panel.allowedContentTypes = mode == .photo ? [.image] : [.item]
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
    private let replySource: TelegramMessageActionSource?
    private let replyContextID: UUID?
    @State private var choosing = false
    init(model: TelegramModel, replySource: TelegramMessageActionSource? = nil, replyContextID: UUID? = nil) {
        self.model = model; upload = model.upload; self.replySource = replySource; self.replyContextID = replyContextID
    }
    var body: some View {
        Menu {
            Button("Фото", systemImage: "photo") { choose(.photo) }
                .accessibilityIdentifier("telegram.upload.choosePhoto")
            Button("Файл", systemImage: "doc") { choose(.file) }
                .accessibilityIdentifier("telegram.upload.chooseFile")
        } label: { Image(systemName: "paperclip").font(.system(size: 22)).frame(width: 32, height: 32) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Прикрепить фото или файл").accessibilityLabel("Прикрепить")
            .accessibilityIdentifier("telegram.upload.attach")
            .disabled(choosing || capturedTarget == nil || upload.phase != .idle || model.isRestoringPendingUpload || model.pendingUploadRecoveryError != nil || model.isRestoringComposerDraft || model.composerDraftRecoveryError != nil)
    }
    private var capturedTarget: TelegramUploadTarget? {
        model.uploadTarget(replyTo: replySource, contextID: replyContextID ?? model.uploadContextID)
    }
    private func choose(_ mode: TelegramUploadMode) {
        guard !choosing, let target = capturedTarget else { return }
        let captionInput = model.composerInput
        let contextID = model.uploadContextID
        choosing = true
        Task { @MainActor in
            defer { choosing = false }
            guard let source = await TelegramUploadPanel.choose(mode: mode) else { return }
            model.prepareUpload(source: source, mode: mode, target: target, captionInput: captionInput, contextID: contextID)
        }
    }
}

/// Presentation stays attached while the inline observation bar appears/disappears.
struct TelegramUploadView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var upload: TelegramUploadController
    init(model: TelegramModel) { self.model = model; upload = model.upload }
    var body: some View {
        let contextID = upload.preparationContextID
        VStack(alignment: .leading, spacing: 8) {
            if model.isRestoringPendingUpload {
                ProgressView("Восстановление подготовленного вложения…")
                    .controlSize(.small).accessibilityIdentifier("telegram.upload.recoveryLoading")
            }
            if let error = model.pendingUploadRecoveryError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("telegram.upload.recoveryError")
                    Spacer()
                    Button("Повторить восстановление", action: model.retryPendingUploadRecovery)
                        .accessibilityIdentifier("telegram.upload.retryRestore")
                }
            }
            if let status = upload.cancellationStatus {
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("telegram.upload.cancellationStatus")
                    Spacer()
                    if upload.isCancellationBusy { ProgressView().controlSize(.small) }
                    if upload.canRetryCancellation {
                        Button("Повторить сохранение отмены", action: upload.retryCancellation)
                            .accessibilityIdentifier("telegram.upload.retryCancellation")
                    }
                }
            }
            if let status = upload.detachedRecoveryStatus {
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("telegram.upload.detachedRecoveryStatus")
                    Spacer()
                    if upload.canRetryDetachedRecovery {
                        Button("Повторить сохранение параметров", action: upload.retryDetachedRecovery)
                            .accessibilityIdentifier("telegram.upload.retryDetachedRecovery")
                    }
                }
            }
            if !upload.showsPreparationPreview, upload.phase != .idle || upload.error != nil {
                if let target = upload.target {
                    Label("Получатель: \(target.title)", systemImage: "paperplane").font(.callout)
                }
                HStack {
                    TelegramUploadStatusView(upload: upload, synthetic: model.isSyntheticPreview)
                    Spacer()
                    Button("Закрыть наблюдение", action: upload.clear)
                        .accessibilityIdentifier("telegram.upload.clear")
                }
                if let error = upload.error {
                    Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("telegram.upload.error")
                }
            }
        }
        .padding(model.isRestoringPendingUpload || model.pendingUploadRecoveryError != nil || upload.cancellationStatus != nil || upload.detachedRecoveryStatus != nil ? 16 :
            upload.showsPreparationPreview || (upload.phase == .idle && upload.error == nil) ? 0 : 16)
        .sheet(isPresented: Binding(get: { upload.showsPreparationPreview }, set: { shown in
            if !shown, let contextID { upload.dismissPreparation(contextID: contextID) }
        })) {
            if let contextID {
                TelegramUploadPreviewView(model: model, contextID: contextID).id(contextID)
            }
        }
    }
}

struct TelegramUploadStatusView: View {
    @ObservedObject var upload: TelegramUploadController
    let synthetic: Bool
    var body: some View {
        HStack(spacing: 8) {
            if upload.phase == .preparing || upload.phase == .storing || upload.phase == .enqueuing {
                ProgressView().controlSize(.small)
            }
            Text(status).font(.callout).accessibilityIdentifier("telegram.upload.status")
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
            synthetic ? "Синтетическая очередь: отправки в Telegram нет." :
                progress.map { "В локальной очереди • \(Int($0 * 100))%. Доставка не подтверждена." } ?? "В локальной очереди. Доставка не подтверждена."
        case .queueFailed: "Telegram сообщил об ошибке очереди. Автоматический повтор не выполняется."
        case .rejected: "Вложение не поставлено в очередь."
        case .uncertain: "Результат пока неизвестен. Не отправляйте вложение повторно."
        case .cancelled: "Подготовка отменена."
        case .failed: "Не удалось подготовить вложение."
        }
    }
}

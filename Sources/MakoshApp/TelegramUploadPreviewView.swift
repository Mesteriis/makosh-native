import SwiftUI
import MakoshTelegram

struct TelegramUploadPreviewView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var upload: TelegramUploadController
    let contextID: UUID
    @State private var captionError: String?
    init(model: TelegramModel, contextID: UUID) {
        self.model = model; upload = model.upload; self.contextID = contextID
    }
    private var canDismiss: Bool { upload.canCancel || upload.phase == .uncertain }
    private var isVisualMedia: Bool { upload.file?.mode == .photo || upload.file?.mode == .video }
    private var title: String {
        switch upload.file?.mode {
        case .photo: "Отправить фото"
        case .video: "Отправить видео"
        default: "Отправить вложение"
        }
    }
    var body: some View {
        let captionContext = upload.captionContextID
        let captionRevision = upload.captionRevision
        let captionAbove = upload.captionAboveMedia
        let mediaSpoiler = upload.mediaSpoiler
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if isVisualMedia {
                    Menu {
                        spoilerButton(context: captionContext, revision: captionRevision, spoiler: mediaSpoiler)
                        placementButton(context: captionContext, revision: captionRevision, above: captionAbove)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel(upload.file?.mode == .video ? "Действия с видео" : "Действия с фото").accessibilityIdentifier("telegram.upload.actions")
                }
                Button { upload.dismissPreparation(contextID: contextID) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).disabled(!canDismiss).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Отменить подготовку").accessibilityIdentifier("telegram.upload.cancel")
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain).accessibilityIdentifier("telegram.upload.header")
            .contextMenu {
                if isVisualMedia {
                    spoilerButton(context: captionContext, revision: captionRevision, spoiler: mediaSpoiler)
                    placementButton(context: captionContext, revision: captionRevision, above: captionAbove)
                }
            }
            if let target = upload.target {
                Label("Получатель: \(target.title)", systemImage: "paperplane").font(.callout)
                if let source = target.replySource {
                    Label("Ответ на: \(source.text.isEmpty ? "Сообщение с вложением" : telegramSourcePreview(source))", systemImage: "arrowshape.turn.up.left")
                        .font(.callout).lineLimit(3).accessibilityIdentifier("telegram.upload.replySubject")
                }
            }
            if let file = upload.file {
                TelegramUploadFilePreview(file: file, mediaSpoiler: mediaSpoiler, upload: upload, contextID: contextID).id(file.id)
            }
            else { ProgressView("Подготовка вложения…").frame(maxWidth: .infinity, minHeight: 140) }
            if upload.file != nil {
                let captionContext = upload.captionContextID
                TelegramRichTextEditor(value: Binding(get: { upload.captionInput.formattedText }, set: { _ in }),
                    error: $captionError, selection: upload.captionInput.selection, accessibilityID: "telegram.upload.caption",
                    placeholder: "Подпись к вложению", inputChanged: { input in
                        _ = upload.updateCaptionInput(input, contextID: captionContext)
                    }, submit: send)
                    .id(captionContext).disabled(upload.phase != .ready)
                Text("Подпись: \(upload.caption.utf16.count)/1024").font(.caption).foregroundStyle(.secondary)
            }
            if let error = upload.error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("telegram.upload.error")
            }
            if let status = upload.recoveryStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("telegram.upload.recoveryStatus")
            }
            if let captionError { Text(captionError).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                TelegramUploadStatusView(upload: upload, synthetic: model.isSyntheticPreview)
                Spacer()
                if upload.canRetryRecovery {
                    Button("Повторить сохранение", action: upload.retryRecovery)
                        .accessibilityIdentifier("telegram.upload.retrySave")
                }
                if upload.phase == .uncertain {
                    Button("Закрыть наблюдение") { upload.dismissPreparation(contextID: contextID) }
                        .accessibilityIdentifier("telegram.upload.clear")
                } else {
                    if isVisualMedia {
                        Menu {
                            sendAsSpoilerButton(revision: captionRevision)
                        } label: {
                            Text(model.isSyntheticPreview ? "Имитировать очередь" : "Отправить")
                        } primaryAction: { send() }
                        .menuIndicator(.hidden)
                        .buttonStyle(.borderedProminent).disabled(!upload.canSend || captionError != nil)
                        .accessibilityIdentifier("telegram.upload.send")
                        .contextMenu { sendAsSpoilerButton(revision: captionRevision) }
                    } else {
                        Button(model.isSyntheticPreview ? "Имитировать очередь" : "Отправить", action: send)
                        .buttonStyle(.borderedProminent).disabled(!upload.canSend || captionError != nil)
                        .accessibilityIdentifier("telegram.upload.send")
                    }
                }
            }
        }
        .padding(20).frame(width: 520)
        .interactiveDismissDisabled(!canDismiss)
        .onDisappear { upload.dismissPreparation(contextID: contextID) }
    }
    private func placementButton(context: UUID, revision: UUID, above: Bool) -> some View {
        Button(above ? "Переместить подпись вниз" : "Переместить подпись вверх") {
            upload.updateCaptionPlacement(!above, contextID: context, revision: revision)
        }
        .disabled(upload.phase != .ready || upload.preparationContextID != contextID)
        .accessibilityIdentifier("telegram.upload.captionPlacement")
    }
    private func spoilerButton(context: UUID, revision: UUID, spoiler: Bool) -> some View {
        Button(spoiler ? "Отключить спойлер" : "Скрыть под спойлером") {
            upload.updateMediaSpoiler(!spoiler, contextID: context, revision: revision)
        }
        .disabled(upload.phase != .ready || upload.preparationContextID != contextID)
        .accessibilityIdentifier("telegram.upload.spoiler")
    }
    private func send() {
        guard upload.canSend, captionError == nil else { return }
        upload.send(contextID: contextID)
    }
    private func sendAsSpoilerButton(revision: UUID) -> some View {
        Button("Отправить под спойлером") {
            guard captionError == nil else { return }
            upload.sendAsSpoiler(contextID: contextID, revision: revision)
        }
        .disabled(!upload.canSend || captionError != nil || upload.preparationContextID != contextID)
        .accessibilityIdentifier("telegram.upload.sendAsSpoiler")
    }
}

private struct TelegramUploadFilePreview: View {
    let file: TelegramUploadFile
    let mediaSpoiler: Bool
    @ObservedObject var upload: TelegramUploadController
    let contextID: UUID
    @State private var preview: TelegramImagePreview?
    @State private var failed = false
    private var isVideo: Bool { file.mode == .video }
    var body: some View {
        VStack(spacing: 10) {
            if file.mode == .photo || isVideo {
                if let preview {
                    ZStack {
                        Image(preview.image, scale: 1, label: Text(isVideo ? "Первый кадр видео" : "Предпросмотр фото")).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 240)
                            .blur(radius: mediaSpoiler ? 18 : 0)
                            .accessibilityHidden(mediaSpoiler)
                            .accessibilityIdentifier(isVideo ? "telegram.upload.videoPreview" : "telegram.upload.photoPreview")
                        if isVideo, !mediaSpoiler { TelegramUploadVideoPlayerView(playback: upload.videoPlayback) }
                        if mediaSpoiler {
                            Label(isVideo ? "Видео под спойлером" : "Фото под спойлером", systemImage: "eye.slash")
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.thinMaterial)
                                .accessibilityIdentifier("telegram.upload.spoilerPreview")
                        }
                    }.clipped()
                } else if failed {
                    Label(isVideo ? "Не удалось показать первый кадр видео" : "Не удалось показать фото", systemImage: "photo.badge.exclamationmark")
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else { ProgressView().frame(maxWidth: .infinity, minHeight: 140) }
            } else {
                Image(systemName: "doc.fill").font(.system(size: 48)).foregroundStyle(.secondary).padding(18)
            }
            Text("\(file.name) • \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                .font(.callout).lineLimit(2).accessibilityIdentifier("telegram.upload.file")
            if file.mode == .photo {
                Text("JPEG до 2560 пикселей, без исходных метаданных").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .task(id: file.id) {
            guard file.mode == .photo || file.mode == .video else { return }
            do {
                let result = try await TelegramUploadFileIO.preview(file)
                guard !Task.isCancelled else { return }
                preview = result
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
        .task(id: isVideo && !mediaSpoiler && upload.phase == .ready) {
            if isVideo && !mediaSpoiler && upload.phase == .ready { await upload.openVideoPreview(contextID: contextID) }
            else { upload.stopVideoPreview(contextID: contextID) }
        }
        .onDisappear { upload.stopVideoPreview(contextID: contextID) }
    }
}

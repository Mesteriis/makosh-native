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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(upload.file?.mode == .photo ? "Отправить фото" : "Отправить вложение").font(.headline)
                Spacer()
                Button { upload.dismissPreparation(contextID: contextID) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).disabled(!canDismiss).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Отменить подготовку").accessibilityIdentifier("telegram.upload.cancel")
            }
            if let target = upload.target {
                Label("Получатель: \(target.title)", systemImage: "paperplane").font(.callout)
                if let source = target.replySource {
                    Label("Ответ на: \(source.text.isEmpty ? "Сообщение с вложением" : telegramSourcePreview(source))", systemImage: "arrowshape.turn.up.left")
                        .font(.callout).lineLimit(3).accessibilityIdentifier("telegram.upload.replySubject")
                }
            }
            if let file = upload.file { TelegramUploadFilePreview(file: file).id(file.id) }
            else { ProgressView("Подготовка вложения…").frame(maxWidth: .infinity, minHeight: 140) }
            if upload.file != nil {
                let captionContext = upload.captionContextID
                TelegramRichTextEditor(value: Binding(get: { upload.captionInput.formattedText }, set: { _ in }),
                    error: $captionError, selection: upload.captionInput.selection, accessibilityID: "telegram.upload.caption",
                    placeholder: "Подпись к вложению", inputChanged: { input in
                        _ = upload.updateCaptionInput(input, contextID: captionContext)
                    })
                    .id(captionContext).disabled(upload.phase != .ready)
                Text("Подпись: \(upload.caption.utf16.count)/1024").font(.caption).foregroundStyle(.secondary)
            }
            if let error = upload.error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("telegram.upload.error")
            }
            if let captionError { Text(captionError).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                TelegramUploadStatusView(upload: upload, synthetic: model.isSyntheticPreview)
                Spacer()
                if upload.phase == .uncertain {
                    Button("Закрыть наблюдение") { upload.dismissPreparation(contextID: contextID) }
                        .accessibilityIdentifier("telegram.upload.clear")
                } else {
                    Button(model.isSyntheticPreview ? "Имитировать очередь" : "Отправить") { upload.send(contextID: contextID) }
                        .buttonStyle(.borderedProminent).disabled(!upload.canSend || captionError != nil)
                        .accessibilityIdentifier("telegram.upload.send")
                }
            }
        }
        .padding(20).frame(width: 520)
        .interactiveDismissDisabled(!canDismiss)
        .onDisappear { upload.dismissPreparation(contextID: contextID) }
    }
}

private struct TelegramUploadFilePreview: View {
    let file: TelegramUploadFile
    @State private var preview: TelegramImagePreview?
    @State private var failed = false
    var body: some View {
        VStack(spacing: 10) {
            if file.mode == .photo {
                if let preview {
                    Image(preview.image, scale: 1, label: Text("Предпросмотр фото")).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 240)
                        .accessibilityIdentifier("telegram.upload.photoPreview")
                } else if failed {
                    Label("Не удалось показать фото", systemImage: "photo.badge.exclamationmark")
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
            guard file.mode == .photo else { return }
            do {
                let result = try await TelegramUploadFileIO.preview(file)
                guard !Task.isCancelled else { return }
                preview = result
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

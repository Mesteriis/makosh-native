import SwiftUI
import MakoshTelegram

struct TelegramUploadPreviewView: View {
    @AppStorage(TelegramUploadPhotoSize.preferenceKey) private var sendLargePhotos = false
    @ObservedObject var model: TelegramModel
    @ObservedObject private var upload: TelegramUploadController
    @ObservedObject private var emojiCatalog: TelegramCustomEmojiCatalogController
    let contextID: UUID
    @State private var captionError: String?
    @State private var emojiPicker: CaptionEmojiPickerSnapshot?
    @State private var expectedEmojiInput: TelegramComposerInput?
    @State private var pickedEmojiDescriptors: [Int64: TelegramCustomEmojiDescriptor] = [:]
    @State private var coverEditor: TelegramVideoCoverEditorPresentation?
    @State private var coverChoiceID: UUID?
    @State private var coverTask: Task<Void, Never>?
    @State private var coverError: String?
    private struct CaptionEmojiPickerSnapshot {
        let input: TelegramComposerInput
        let revision: UUID
        let captionContextID: UUID
        let preparationID: UUID
        let catalogContextID: UUID
        let target: TelegramUploadTarget
    }
    init(model: TelegramModel, contextID: UUID) {
        self.model = model; upload = model.upload; emojiCatalog = model.customEmojiCatalog; self.contextID = contextID
    }
    private var canDismiss: Bool { upload.canCancel || upload.phase == .uncertain }
    private var canUseMediaOptions: Bool { upload.canUseMediaOptions && model.composerSupportsExtendedMediaOptions }
    private var title: String {
        if upload.presentation == .archive { return "Отправить архив" }
        if upload.items.count > 1 { return "Отправить вложения (\(upload.items.count))" }
        return switch upload.file?.mode {
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
                if upload.canUseFilePresentation || upload.canSwitchPresentation || canUseMediaOptions || upload.items.count > 1 {
                    Menu {
                        presentationButtons(revision: upload.itemsRevision)
                        groupingButton(revision: upload.itemsRevision)
                        videoCoverButtons(revision: upload.videoCoverRevision)
                        if canUseMediaOptions {
                            spoilerButton(context: captionContext, revision: captionRevision, spoiler: mediaSpoiler)
                            placementButton(context: captionContext, revision: captionRevision, above: captionAbove)
                        }
                        photoSizeButton()
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel(upload.items.count > 1 ? "Действия с вложениями" : upload.file?.mode == .video ? "Действия с видео" : upload.file?.mode == .photo ? "Действия с фото" : "Действия с вложением").accessibilityIdentifier("telegram.upload.actions")
                        .accessibilityValue(upload.presentation == .archive ? "Архив" : upload.presentation == .file ? "Файлы" : "Медиа")
                }
                Button { upload.dismissPreparation(contextID: contextID) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).disabled(!canDismiss).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Отменить подготовку").accessibilityIdentifier("telegram.upload.cancel")
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain).accessibilityIdentifier("telegram.upload.header")
            .contextMenu {
                presentationButtons(revision: upload.itemsRevision)
                groupingButton(revision: upload.itemsRevision)
                if canUseMediaOptions {
                    videoCoverButtons(revision: upload.videoCoverRevision)
                    spoilerButton(context: captionContext, revision: captionRevision, spoiler: mediaSpoiler)
                    placementButton(context: captionContext, revision: captionRevision, above: captionAbove)
                }
                photoSizeButton()
            }
            if let target = upload.target {
                Label("Получатель: \(target.title)", systemImage: "paperplane").font(.callout)
                if let source = target.replySource {
                    Label("Ответ на: \(source.text.isEmpty ? "Сообщение с вложением" : telegramSourcePreview(source))", systemImage: "arrowshape.turn.up.left")
                        .font(.callout).lineLimit(3).accessibilityIdentifier("telegram.upload.replySubject")
                }
            }
            if upload.items.count > 1 {
                TelegramUploadBatchPreview(upload: upload, contextID: contextID)
            } else if let file = upload.file {
                TelegramUploadFilePreview(file: file, mediaSpoiler: mediaSpoiler, upload: upload, contextID: contextID).id(file.id)
            }
            else { ProgressView("Подготовка вложения…").frame(maxWidth: .infinity, minHeight: 140) }
            if upload.file != nil {
                let usesCaption = upload.usesCaptionPlaceholder
                captionEditor
                Text("\(usesCaption ? "Подпись" : "Комментарий"): \(upload.captionValidationUTF16Count)/\(upload.captionMaximumUTF16Count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = upload.error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("telegram.upload.error")
            }
            if let status = upload.recoveryStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("telegram.upload.recoveryStatus")
            }
            if let captionError { Text(captionError).font(.caption).foregroundStyle(.red) }
            if let coverError { Text(coverError).font(.caption).foregroundStyle(.red).accessibilityIdentifier("telegram.upload.videoCoverError") }
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
                    if canUseMediaOptions {
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
        .modifier(TelegramUploadAppendDropModifier(model: model))
        .interactiveDismissDisabled(!canDismiss)
        .sheet(item: $coverEditor, onDismiss: {
            if let coverChoiceID { upload.cancelVideoCoverEdit(coverChoiceID) }
            coverChoiceID = nil
        }) { editor in
            TelegramVideoCoverEditorView(presentation: editor, upload: upload) { coverEditor = nil }
        }
        .onChange(of: upload.videoCoverEditingID) { _, new in
            if let coverChoiceID, new != coverChoiceID { coverEditor = nil }
            if new != nil { dismissEmojiPicker() }
        }
        .onChange(of: upload.captionInput) { _, input in
            retainPickedDescriptors(for: input)
            guard let snapshot = emojiPicker else { return }
            guard expectedEmojiInput == input, captionSnapshotIsCurrent(snapshot, ignoringInputRevision: true) else {
                dismissEmojiPicker(); return
            }
            expectedEmojiInput = nil
            emojiPicker = .init(input: input, revision: upload.captionRevision,
                captionContextID: snapshot.captionContextID, preparationID: snapshot.preparationID,
                catalogContextID: snapshot.catalogContextID, target: snapshot.target)
        }
        .onChange(of: upload.captionRevision) { _, revision in
            if expectedEmojiInput == nil, let snapshot = emojiPicker, snapshot.revision != revision { dismissEmojiPicker() }
        }
        .onChange(of: upload.captionContextID) { _, _ in dismissEmojiPicker(); pickedEmojiDescriptors = [:] }
        .onChange(of: upload.target) { _, _ in dismissEmojiPicker(); pickedEmojiDescriptors = [:] }
        .onChange(of: upload.itemsRevision) { _, _ in dismissEmojiPicker() }
        .onChange(of: upload.phase) { _, phase in if phase != .ready { dismissEmojiPicker() } }
        .onChange(of: emojiCatalog.contextID) { _, _ in dismissEmojiPicker() }
        .onChange(of: upload.isAppendingItems) { _, appending in if appending { dismissEmojiPicker() } }
        .onChange(of: upload.isVideoCoverSaving) { _, saving in if saving { dismissEmojiPicker() } }
        .onDisappear {
            dismissEmojiPicker(); pickedEmojiDescriptors = [:]
            coverTask?.cancel()
            if let coverChoiceID { upload.cancelVideoCoverEdit(coverChoiceID) }
            coverEditor = nil
            upload.dismissPreparation(contextID: contextID)
        }
    }
    private var captionEditor: some View {
        let captionContext = upload.captionContextID
        let usesCaption = upload.usesCaptionPlaceholder
        return HStack(alignment: .bottom, spacing: 8) {
            TelegramRichTextEditor(value: Binding(get: { upload.captionInput.formattedText }, set: { _ in }),
                error: $captionError, selection: upload.captionInput.selection, accessibilityID: "telegram.upload.caption",
                placeholder: usesCaption ? "Добавить подпись…" : "Добавить комментарий…",
                accessibilityLabel: usesCaption ? "Подпись к вложению" : "Комментарий к вложениям", inputChanged: { input in
                    _ = upload.updateCaptionInput(input, contextID: captionContext)
                }, submit: send, customEmojiDescriptors: captionEmojiDescriptors,
                customEmojiContext: model.customEmojiPlaybackContext,
                customEmojiInsertion: upload.captionCustomEmojiInsertion,
                customEmojiInputContextID: captionContext,
                consumeCustomEmojiInsertion: { id, input in upload.consumeCaptionCustomEmojiInsertion(id: id, expectedInput: input) })
                .id(captionContext).disabled(upload.phase != .ready || upload.isAppendingItems || upload.videoCoverEditingID != nil || upload.isVideoCoverSaving)
            captionEmojiButton
        }
    }
    private var captionEmojiButton: some View {
        Button {
            guard upload.canInsertCaptionCustomEmoji, let target = upload.target,
                  let preparationID = upload.preparationContextID,
                  preparationID == contextID, emojiCatalog.snapshot?.accountID == target.accountID else { return }
            expectedEmojiInput = nil
            emojiPicker = .init(input: upload.captionInput, revision: upload.captionRevision,
                captionContextID: upload.captionContextID, preparationID: preparationID,
                catalogContextID: emojiCatalog.contextID, target: target)
        } label: { Image(systemName: "face.smiling").font(.system(size: 21)).frame(width: 28, height: 32) }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .accessibilityLabel("Эмодзи в подписи").accessibilityIdentifier("telegram.upload.customEmoji.open")
        .disabled(!upload.canInsertCaptionCustomEmoji || model.customEmojiPlaybackContext == nil || emojiCatalog.snapshot?.accountID != upload.target?.accountID)
        .popover(isPresented: Binding(get: { emojiPicker != nil }, set: { if !$0 { dismissEmojiPicker() } }), arrowEdge: .top) {
            if let snapshot = emojiPicker {
                TelegramCustomEmojiPicker(catalog: emojiCatalog, playbackContext: model.customEmojiPlaybackContext,
                    chatID: snapshot.target.chatID) { descriptor, catalogContextID in
                        guard expectedEmojiInput == nil, catalogContextID == snapshot.catalogContextID,
                              captionSnapshotIsCurrent(snapshot),
                              let next = try? TelegramCustomEmojiInsertion.applying(descriptor, to: snapshot.input),
                              upload.requestCaptionCustomEmojiInsertion(descriptor: descriptor, catalog: emojiCatalog,
                                catalogContextID: catalogContextID, expectedInput: snapshot.input,
                                contextID: snapshot.captionContextID, revision: snapshot.revision,
                                preparationID: snapshot.preparationID) else { return }
                        pickedEmojiDescriptors[descriptor.fileID] = descriptor
                        expectedEmojiInput = next
                    }
            }
        }
    }
    private var captionEmojiDescriptors: [Int64: TelegramCustomEmojiDescriptor] {
        model.customEmojiDescriptors.merging(pickedEmojiDescriptors, uniquingKeysWith: { _, picked in picked })
    }
    private func retainPickedDescriptors(for input: TelegramComposerInput) {
        let ids = Set(input.formattedText.entities.compactMap { entity -> Int64? in
            if case let .customEmoji(_, fileID) = entity.kind { return fileID }; return nil
        }.prefix(1024))
        pickedEmojiDescriptors = pickedEmojiDescriptors.filter { ids.contains($0.key) }
    }
    private func captionSnapshotIsCurrent(_ snapshot: CaptionEmojiPickerSnapshot, ignoringInputRevision: Bool = false) -> Bool {
        upload.canInsertCaptionCustomEmoji && contextID == snapshot.preparationID &&
            upload.preparationContextID == snapshot.preparationID && upload.captionContextID == snapshot.captionContextID &&
            upload.target == snapshot.target && emojiCatalog.contextID == snapshot.catalogContextID &&
            emojiCatalog.snapshot?.accountID == snapshot.target.accountID &&
            (ignoringInputRevision || upload.captionInput == snapshot.input && upload.captionRevision == snapshot.revision)
    }
    private func dismissEmojiPicker() { emojiPicker = nil; expectedEmojiInput = nil }
    @ViewBuilder private func photoSizeButton() -> some View {
        if upload.presentation == .media, !upload.isRecordedRoundVideo {
            Divider()
            Toggle("Отправлять большие фотографии", isOn: $sendLargePhotos)
                .help("Увеличенный размер применяется к новым подготовкам фотографий.")
                .accessibilityIdentifier("telegram.upload.sendLargePhotos")
                .accessibilityValue(sendLargePhotos ? "Включено" : "Выключено")
        }
    }
    @ViewBuilder private func videoCoverButtons(revision: UUID) -> some View {
        if model.composerSupportsExtendedMediaOptions, upload.items.count == 1, upload.file?.mode == .video {
            Button(upload.file?.videoCover == nil ? "Добавить обложку" : "Изменить обложку") { chooseVideoCover(revision: revision) }
                .disabled(!upload.canEditVideoCover).accessibilityIdentifier("telegram.upload.videoCover.choose")
            if upload.file?.videoCover != nil {
                Button("Удалить обложку") {
                    guard let edit = upload.beginVideoCoverEdit(contextID: contextID, revision: revision) else { return }
                    if !upload.commitVideoCover(nil, editID: edit) { upload.cancelVideoCoverEdit(edit) }
                }.disabled(!upload.canEditVideoCover).accessibilityIdentifier("telegram.upload.videoCover.remove")
            }
            Divider()
        }
    }
    @ViewBuilder private func presentationButtons(revision: UUID) -> some View {
        if upload.canSwitchPresentation {
            Button {
                upload.updatePresentation(.media, contextID: contextID, revision: revision)
            } label: {
                Label("Отправить как медиа", systemImage: upload.presentation == .media ? "checkmark" : "photo.on.rectangle")
            }.disabled(!upload.canEditPresentation).accessibilityIdentifier("telegram.upload.asMedia")
        }
        if upload.canUseFilePresentation {
            Button {
                upload.updatePresentation(.file, contextID: contextID, revision: revision)
            } label: {
                Label(upload.items.count > 1 ? "Отправить как файлы" : "Отправить как файл",
                      systemImage: upload.presentation == .file ? "checkmark" : "doc")
            }.disabled(!upload.canEditPresentation).accessibilityIdentifier("telegram.upload.asFile")
        }
        if upload.canUseArchivePresentation {
            Button {
                upload.updatePresentation(.archive, contextID: contextID, revision: revision)
            } label: {
                Label("Отправить как архив", systemImage: upload.presentation == .archive ? "checkmark" : "archivebox")
            }.disabled(!upload.canEditPresentation).accessibilityIdentifier("telegram.upload.asArchive")
        }
        if upload.canSwitchPresentation || upload.canUseFilePresentation || upload.canUseArchivePresentation { Divider() }
    }
    @ViewBuilder private func groupingButton(revision: UUID) -> some View {
        if upload.items.count > 1 {
            Button(upload.isGrouped ? "Отправить отдельно" : "Сгруппировать") {
                upload.updateGrouping(!upload.isGrouped, contextID: contextID, revision: revision)
            }.disabled(!upload.canEditItems || (!upload.isGrouped && !upload.canGroupItems)).accessibilityIdentifier("telegram.upload.grouping")
            Divider()
        }
    }
    private func chooseVideoCover(revision: UUID) {
        guard let video = upload.file?.video,
              let edit = upload.beginVideoCoverEdit(contextID: contextID, revision: revision) else { return }
        coverChoiceID = edit; coverError = nil
        coverTask = Task { @MainActor in
            defer { coverTask = nil }
            guard let source = await TelegramVideoCoverPanel.choose(), !Task.isCancelled,
                  upload.videoCoverEditingID == edit else { upload.cancelVideoCoverEdit(edit); return }
            do {
                let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
                guard !Task.isCancelled, upload.videoCoverEditingID == edit else {
                    try? TelegramUploadVideoCoverIO.discardSelection(selection); return
                }
                do { coverEditor = try TelegramVideoCoverEditorPresentation(id: edit, selection: selection, video: video) }
                catch { try? TelegramUploadVideoCoverIO.discardSelection(selection); throw error }
            } catch {
                guard !Task.isCancelled, upload.videoCoverEditingID == edit else { return }
                upload.cancelVideoCoverEdit(edit)
                coverError = "Не удалось открыть изображение для обложки. Выберите другой файл."
            }
        }
    }
    private func placementButton(context: UUID, revision: UUID, above: Bool) -> some View {
        Button(above ? "Переместить подпись вниз" : "Переместить подпись вверх") {
            upload.updateCaptionPlacement(!above, contextID: context, revision: revision)
        }
        .disabled(upload.phase != .ready || upload.videoCoverEditingID != nil || upload.isVideoCoverSaving || upload.preparationContextID != contextID)
        .accessibilityIdentifier("telegram.upload.captionPlacement")
    }
    private func spoilerButton(context: UUID, revision: UUID, spoiler: Bool) -> some View {
        Button(spoiler ? "Отключить спойлер" : "Скрыть под спойлером") {
            upload.updateMediaSpoiler(!spoiler, contextID: context, revision: revision)
        }
        .disabled(upload.phase != .ready || upload.videoCoverEditingID != nil || upload.isVideoCoverSaving || upload.preparationContextID != contextID)
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
    private var previewKey: String { file.id.uuidString + ":" + (file.videoCover?.id.uuidString ?? "frame") }
    private var playsVideo: Bool { isVideo && file.videoCover == nil && !mediaSpoiler && upload.phase == .ready && upload.videoCoverEditingID == nil && !upload.isVideoCoverSaving }
    var body: some View {
        VStack(spacing: 10) {
            if file.mode == .photo || isVideo {
                TelegramUploadSingleMediaLayout(file: file) {
                    if let preview {
                        ZStack {
                            Image(preview.image, scale: 1, label: Text(file.videoCover != nil ? "Обложка видео" : (isVideo ? "Первый кадр видео" : "Предпросмотр фото"))).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .blur(radius: mediaSpoiler ? 18 : 0)
                                .accessibilityHidden(mediaSpoiler)
                                .accessibilityIdentifier(file.videoCover != nil ? "telegram.upload.videoCoverPreview" : (isVideo ? "telegram.upload.videoPreview" : "telegram.upload.photoPreview"))
                            if playsVideo { TelegramUploadVideoPlayerView(playback: upload.videoPlayback) }
                            if mediaSpoiler {
                                Label(isVideo ? "Видео под спойлером" : "Фото под спойлером", systemImage: "eye.slash")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.thinMaterial)
                                    .accessibilityIdentifier("telegram.upload.spoilerPreview")
                            }
                        }
                    } else if failed {
                        Label(isVideo ? "Не удалось показать первый кадр видео" : "Не удалось показать фото", systemImage: "photo.badge.exclamationmark")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.clipped()
            } else {
                TelegramUploadDocumentPreview(file: file, isActive: upload.phase == .ready && upload.videoCoverEditingID == nil && !upload.isVideoCoverSaving)
            }
            if file.mode != .file {
                Text("\(file.name) • \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                .font(.callout).lineLimit(2).accessibilityIdentifier("telegram.upload.file")
            }
            if file.mode == .photo {
                Text("JPEG без исходных метаданных").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity)
        .background { if file.mode != .file { RoundedRectangle(cornerRadius: 8).fill(.quaternary) } }
        .task(id: previewKey) {
            guard file.mode == .photo || file.mode == .video else { return }
            preview = nil; failed = false
            do {
                let result = try await TelegramUploadFileIO.preview(file)
                guard !Task.isCancelled else { return }
                preview = result
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
        .task(id: playsVideo) {
            if playsVideo { await upload.openVideoPreview(contextID: contextID) }
            else { upload.stopVideoPreview(contextID: contextID) }
        }
        .onDisappear { upload.stopVideoPreview(contextID: contextID) }
    }
}

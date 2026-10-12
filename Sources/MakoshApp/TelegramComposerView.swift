import SwiftUI
import MakoshTelegram

/// The ordinary composer survives detail-view recreation through TelegramModel.
struct TelegramComposerView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var reply: TelegramComposerReplyController
    @ObservedObject private var actions: TelegramMessageActionsController
    @ObservedObject private var selectedDelete: TelegramSelectedMessagesDeleteController
    @ObservedObject private var upload: TelegramUploadController
    @ObservedObject private var forward: TelegramComposerForwardController
    @ObservedObject private var voice: TelegramVoiceRecordingController
    @ObservedObject private var emojiCatalog: TelegramCustomEmojiCatalogController
    @State private var editorError: String?
    @State private var emojiPicker: EmojiPickerSnapshot?
    @State private var expectedEmojiInput: TelegramComposerInput?
    private struct EmojiPickerSnapshot {
        let input: TelegramComposerInput
        let revision: UUID?
        let contextID: UUID
        let catalogContextID: UUID
        let chatID: Int64
    }
    init(model: TelegramModel) {
        self.model = model; reply = model.composerReply; actions = model.messageActions; upload = model.upload; forward = model.composerForward
        selectedDelete = model.selectedMessagesDelete
        voice = model.voiceRecording; emojiCatalog = model.customEmojiCatalog
    }
    var body: some View {
        replyAccessory
        TelegramForwardAccessoryView(model: model)
        HStack(alignment: .bottom, spacing: 12) {
            if voice.isActive {
                recordingLine
            } else {
            TelegramAttachButtons(model: model, replySource: reply.resolved?.source,
                replyContextID: model.messageActionContextID)
                .disabled(reply.preventsSend || !model.composerSupportsAttachments || actions.isBusy || actions.phase == .uncertain || model.selectedMessagesDeletionBlocksActions)
                .help(model.composerForwardIntent != nil ? "Сначала отправьте или отмените пересылку." : model.composerSupportsAttachments ? "Прикрепить фото, видео или файл" : "Форматирование этого черновика пока не поддерживается для вложений.")
            if let chatID = model.selectedChatID {
                let contextID = model.messageActionContextID
                TelegramRichTextEditor(value: Binding(get: { model.composerInput.formattedText },set: { _ in }),
                    error: $editorError,selection: model.composerInput.selection,accessibilityID: "telegram.composer",
                    placeholder: model.composerForwardIntent == nil ? "Сообщение в Telegram" : "Добавить комментарий…",inputChanged: { input in
                        _ = model.updateComposerInput(input,contextID: contextID,chatID: chatID)
                    },submit: send,
                    customEmojiDescriptors: model.customEmojiDescriptors,
                    customEmojiContext: model.customEmojiPlaybackContext,
                    customEmojiInsertion: model.customEmojiInsertion,
                    customEmojiInputContextID: contextID,
                    consumeCustomEmojiInsertion: { id, input in
                        model.consumeCustomEmojiInsertion(id: id, expectedInput: input)
                    })
                    .id("\(contextID.uuidString):\(chatID)")
                    .disabled(editorIsLocked)
                emojiButton
            }
            }
            if model.composerInput.formattedText.text.isEmpty && model.composerForwardIntent == nil {
                TelegramVoiceRecordButton(model: model, phase: voice.phase).frame(width: 32, height: 32)
                    .disabled(!model.canStartVoiceRecording && voice.phase != .recording && voice.phase != .locked && voice.phase != .authorizing)
            } else {
            Button(action: send) { Image(systemName: "paperplane.fill").font(.system(size: 22)).frame(width: 32, height: 32) }
                .buttonStyle(.plain).foregroundStyle(.tint).accessibilityLabel("Отправить")
                .disabled(!canSend)
                .accessibilityIdentifier("telegram.send")
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
        .onChange(of: model.selectedChatID) { _,_ in editorError = nil; dismissEmojiPicker() }
        .onChange(of: model.messageActionContextID) { _,_ in editorError = nil; dismissEmojiPicker() }
        .onChange(of: emojiCatalog.contextID) { _,_ in dismissEmojiPicker() }
        .onChange(of: model.composerInput) { _, input in
            guard let snapshot = emojiPicker else { return }
            guard expectedEmojiInput == input, snapshot.chatID == model.selectedChatID,
                  snapshot.contextID == model.messageActionContextID,
                  snapshot.catalogContextID == emojiCatalog.contextID else { dismissEmojiPicker(); return }
            // Advance only after our admitted native edit reports its exact result.
            // Other changes leave the opening snapshot stale and close the picker.
            expectedEmojiInput = nil
            emojiPicker = .init(input: input, revision: model.composerInputRevision,
                contextID: snapshot.contextID, catalogContextID: snapshot.catalogContextID, chatID: snapshot.chatID)
        }
        .onExitCommand { if voice.isActive { voice.requestCancel() } }
        .alert("Удалить запись?", isPresented: Binding(get: { voice.cancelConfirmationID != nil }, set: { if !$0 { voice.dismissCancelConfirmation() } })) {
            if let id = voice.cancelConfirmationID {
                Button("Удалить запись", role: .destructive) { voice.confirmCancel(id: id) }
                    .accessibilityIdentifier("telegram.voice.confirmCancel")
            }
            Button("Продолжить запись", role: .cancel) { voice.dismissCancelConfirmation() }
        }
        if let error = voice.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal,16).accessibilityIdentifier("telegram.voice.error") }
        if let editorError { Text(editorError).font(.caption).foregroundStyle(.red).padding(.horizontal,16) }
        if let conflict = model.serverDraftConflict {
            VStack(alignment: .leading, spacing: 6) {
                Text("Черновик изменился на другом устройстве").font(.caption).fontWeight(.medium)
                Text("Здесь: \(model.draft.isEmpty ? "Пустой черновик" : model.draft)").font(.caption).lineLimit(2)
                Text("На другом устройстве: \(conflict.remoteText.isEmpty ? "Пустой черновик" : conflict.remoteText)").font(.caption).lineLimit(2)
                HStack {
                    Button("Оставить текущий") { model.resolveServerDraftConflict(id: conflict.id, keepLocal: true) }
                        .accessibilityIdentifier("telegram.draft.keepLocal")
                    Button("Принять с другого устройства") { model.resolveServerDraftConflict(id: conflict.id, keepLocal: false) }
                        .accessibilityIdentifier("telegram.draft.useRemote")
                    if model.isResolvingServerDraft { ProgressView().controlSize(.small) }
                }.controlSize(.small)
                    .disabled(model.isResolvingServerDraft || model.isComposerSuspended || model.composerForwardIntent != nil || voice.isActive)
            }.padding(.horizontal,16).padding(.bottom,6)
                .accessibilityIdentifier("telegram.draft.conflict")
        }
        if let recoveryError = model.composerDraftRecoveryError {
            HStack {
                Text(recoveryError).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Повторить загрузку", action: model.retryComposerDraftRestore).controlSize(.small)
            }.padding(.horizontal,16).padding(.bottom,6)
        }
    }
    private var editorIsLocked: Bool {
        model.isComposerSuspended || model.isForwardComposerLocked || model.isRestoringComposerDraft ||
            model.isResolvingServerDraft || model.composerDraftRecoveryError != nil
    }
    private var emojiButton: some View {
        Button {
            guard !editorIsLocked, let chatID = model.selectedChatID else { return }
            expectedEmojiInput = nil
            emojiPicker = .init(input: model.composerInput, revision: model.composerInputRevision,
                contextID: model.messageActionContextID, catalogContextID: emojiCatalog.contextID, chatID: chatID)
        } label: { Image(systemName: "face.smiling").font(.system(size: 21)).frame(width: 28, height: 32) }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .accessibilityLabel("Эмодзи").accessibilityIdentifier("telegram.customEmoji.open")
        .disabled(editorIsLocked || !model.composerSupportsCustomEmoji || model.customEmojiPlaybackContext == nil)
        .popover(isPresented: Binding(get: { emojiPicker != nil }, set: { if !$0 { dismissEmojiPicker() } }), arrowEdge: .top) {
            if let snapshot = emojiPicker {
                TelegramCustomEmojiPicker(catalog: emojiCatalog, playbackContext: model.customEmojiPlaybackContext,
                    chatID: snapshot.chatID) { descriptor, catalogContextID in
                        guard expectedEmojiInput == nil, snapshot.catalogContextID == catalogContextID,
                              let next = try? TelegramCustomEmojiInsertion.applying(descriptor, to: snapshot.input),
                              model.requestCustomEmojiInsertion(descriptor: descriptor, catalogContextID: catalogContextID,
                                expectedInput: snapshot.input, contextID: snapshot.contextID,
                                chatID: snapshot.chatID, expectedRevision: snapshot.revision) else { return }
                        expectedEmojiInput = next
                    }
            }
        }
    }
    private func dismissEmojiPicker() { emojiPicker = nil; expectedEmojiInput = nil }
    private var recordingLine: some View {
        HStack(spacing: 10) {
            if voice.phase == .authorizing || voice.phase == .finishing { ProgressView().controlSize(.small) }
            else { Circle().fill(.red).frame(width: 14, height: 14).opacity(0.5 + Double(voice.level) * 0.5) }
            Text(String(format: "%02d:%02d,%02d", Int(voice.duration) / 60, Int(voice.duration) % 60, Int(voice.duration * 100) % 100))
                .monospacedDigit().accessibilityIdentifier("telegram.voice.timer")
            Spacer(minLength: 0)
            Text(voice.phase == .authorizing ? "Проверка доступа…" : voice.phase == .finishing ? "Сохранение записи…" : voice.phase == .locked ? "Запись закреплена" : "Вверх — закрепить · вне кнопки — отменить")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier("telegram.voice.state")
            Button(action: voice.requestCancel) { Image(systemName: "trash") }
                .buttonStyle(.plain).accessibilityLabel("Отменить запись").accessibilityIdentifier("telegram.voice.cancel")
        }.frame(height: 32).accessibilityElement(children: .contain)
    }
    private var canSend: Bool {
        editorError == nil && (!reply.preventsSend || model.composerForwardIntent != nil && model.composerInput.formattedText.text.isEmpty) &&
        (!model.isSyntheticPreview || reply.resolved != nil || model.composerForwardIntent != nil) &&
        !model.isBusy && !actions.isBusy && actions.phase != .uncertain && !model.selectedMessagesDeletionBlocksActions && upload.phase == .idle && model.composerCanSend
    }
    private func send() {
        guard canSend else { return }
        if model.composerForwardIntent != nil { _ = model.sendComposerForward(); return }
        let value = model.composerInput.formattedText
        if let resolved = reply.resolved {
            _ = model.performMessageAction(.replyFormatted(value), source: resolved.source,contextID: model.messageActionContextID)
        } else { _ = model.sendMessage(value) }
    }
    @ViewBuilder private var replyAccessory: some View {
        switch reply.state {
        case .none: EmptyView()
        case let .ready(value):
            accessory(title: value.author, detail: value.source.text.isEmpty ? "Сообщение с вложением" : telegramSourcePreview(value.source))
        case .loading:
            accessory(title: "Ответ", detail: "Восстанавливаем исходное сообщение…")
        case .unavailable:
            accessory(title: "Исходное сообщение недоступно", detail: "Черновик сохранён. Повторите загрузку или отмените ответ.")
            HStack {
                Button("Повторить загрузку", action: reply.retry).controlSize(.small)
                    .accessibilityIdentifier("telegram.reply.retry")
                Spacer()
            }.padding(.horizontal, 16).padding(.bottom, 6)
        }
    }
    private func accessory(title: String, detail: String) -> some View {
        TelegramInputAccessoryView(title: title, detail: detail, symbol: "arrowshape.turn.up.left",
            cancelLabel: "Отменить ответ", cancelID: "telegram.actions.cancelReply", onClose: model.cancelComposerReply)
            .accessibilityIdentifier("telegram.actions.replySubject")
    }
}

import SwiftUI
import MakoshTelegram

struct TelegramForwardAccessoryView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var forward: TelegramComposerForwardController
    @State private var recipientRequest: TelegramForwardRecipientRequest?
    init(model: TelegramModel) { self.model = model; forward = model.composerForward }
    var body: some View {
        if let intent = model.composerForwardIntent {
            TelegramInputAccessoryView(title: title(intent), detail: detail(intent), symbol: "arrowshape.turn.up.right",
                cancelLabel: "Отменить пересылку", cancelID: "telegram.forward.cancel", onClose: model.cancelComposerForward)
                .disabled(model.isForwardComposerLocked)
                .accessibilityIdentifier("telegram.forward.subject")
                .contextMenu {
                    Button("Показывать имя отправителя") { options(intent, names: false, captions: intent.hideCaptions) }
                    Button("Скрыть имя отправителя") { options(intent, names: true, captions: intent.hideCaptions) }
                    if forward.previews.contains(where: \.hasCaption) {
                        Divider()
                        Button("Показывать подпись") { options(intent, names: intent.hideNames, captions: false) }
                        Button("Скрыть подпись") { options(intent, names: true, captions: true) }
                    }
                    Divider()
                    Button("Другой получатель…") {
                        guard let revision = model.composerForwardRevision, let chatID = model.selectedChatID else { return }
                        recipientRequest = .init(intentID: intent.id, contextID: model.messageActionContextID,
                            chatID: chatID, revision: revision)
                    }
                }
                .sheet(item: $recipientRequest) { request in
                    TelegramForwardRecipientPicker(model: model, request: request)
                }
            if let error = forward.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isForwardComposerLocked ? "Проверить локальную очередь" : "Повторить проверку", action: model.refreshForwardReceipt)
                        .controlSize(.small).disabled(model.isRestoringComposerDraft || forward.phase == .committing)
                        .accessibilityIdentifier("telegram.forward.retry")
                }.padding(.horizontal,16).padding(.bottom,6)
            }
            if forward.phase == .committing { ProgressView().controlSize(.small).accessibilityLabel("Постановка пересылки в очередь") }
            if model.isSyntheticPreview {
                Text("Симуляция пересылки: сеть Telegram не используется.").font(.caption).foregroundStyle(.secondary).padding(.horizontal,16)
            }
        }
    }
    private func title(_ intent: TelegramComposerForwardIntent) -> String {
        if intent.hideNames || intent.hideCaptions { return "Пересылка без имени отправителя" }
        return intent.sources.count == 1 ? "Переслать: \(forward.previews.first?.author ?? "сообщение")" : "Переслать сообщения: \(intent.sources.count)"
    }
    private func detail(_ intent: TelegramComposerForwardIntent) -> String {
        if forward.phase == .loading { return "Загружаем исходные сообщения…" }
        guard let preview = forward.previews.first else { return "Исходные сообщения сохранены в черновике" }
        if intent.hideCaptions && preview.hasCaption { return "Вложение без подписи" }
        guard let formatted = preview.formattedText else { return "Форматирование сообщения недоступно" }
        return preview.text.isEmpty ? "Сообщение с вложением" : TelegramMessagePresentation.plainText(formatted)
    }
    private func options(_ intent: TelegramComposerForwardIntent, names: Bool, captions: Bool) {
        model.updateForwardOptions(hideNames: names, hideCaptions: captions, intentID: intent.id, contextID: model.messageActionContextID)
    }
}

private struct TelegramForwardRecipientRequest: Identifiable {
    let id = UUID()
    let intentID: UUID
    let contextID: UUID
    let chatID: Int64
    let revision: UUID
}
private struct TelegramForwardRecipientPicker: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var savedForward: TelegramSavedMessagesForwardController
    let request: TelegramForwardRecipientRequest
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int64?
    @State private var query = ""
    @State private var failed = false
    @State private var submittedSavedID: UUID?
    init(model: TelegramModel, request: TelegramForwardRecipientRequest) {
        self.model = model; self.request = request; self.savedForward = model.savedMessagesForward
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Переслать сообщение").font(.title2.weight(.semibold))
            TextField("Найти получателя", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("telegram.forward.destinationFilter")
            List(selection: $selected) {
                ForEach(model.messageActionForwardDestinations.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { chat in
                    if chat.id == model.savedMessagesChatID {
                        Button { selected = chat.id; submit() } label: {
                            Label(chat.title, systemImage: "bookmark")
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).tag(chat.id).disabled(!canChooseSaved)
                            .help("Сразу переслать в Избранное")
                            .accessibilityIdentifier("telegram.forward.destination.\(chat.id)")
                    } else {
                        Text(chat.title).tag(chat.id).accessibilityIdentifier("telegram.forward.destination.\(chat.id)")
                    }
                }
            }.frame(height: 240).disabled(!validOrigin || submittedSavedID != nil)
            Text("Прежний комментарий и ответ останутся в исходном диалоге.")
                .font(.caption).foregroundStyle(.secondary)
            if failed { Text("Не удалось выбрать получателя. Пересылка сохранена.").foregroundStyle(.red) }
            if submittedSavedID != nil { TelegramSavedMessagesForwardStatus(controller: savedForward, synthetic: model.isSyntheticPreview) }
            HStack {
                Button("Отмена") {
                    if submittedSavedID != nil { savedForward.cancel() }
                    dismiss()
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("telegram.forward.recipientCancel")
                Spacer()
                Button(selected != nil && selected == model.savedMessagesChatID ? "Переслать в Избранное" : "Открыть выбранный диалог", action: submit)
                    .disabled(selected == nil || !validOrigin || submittedSavedID != nil || selected == model.savedMessagesChatID && !canChooseSaved)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("telegram.forward.recipientConfirm")
            }
        }.padding(24).frame(width: 520)
            .interactiveDismissDisabled(submittedSavedID != nil && savedForward.isBusy)
            .onChange(of: savedForward.phase) { _, phase in
                if phase == .queued, submittedSavedID == savedForward.requestID,
                   model.messageActionContextID == request.contextID { dismiss() }
            }
    }
    private var validOrigin: Bool {
        model.messageActionContextID == request.contextID && model.selectedChatID == request.chatID &&
            model.composerForwardRevision == request.revision && model.composerForwardIntent?.id == request.intentID &&
            !model.isForwardComposerLocked
    }
    private var canChooseSaved: Bool {
        validOrigin && submittedSavedID == nil && !savedForward.isBusy && savedForward.phase != .uncertain
    }
    private func submit() {
        guard let selected, validOrigin, submittedSavedID == nil else { failed = true; return }
        if selected == model.savedMessagesChatID, !canChooseSaved { failed = true; return }
        guard model.moveComposerForward(to: selected, intentID: request.intentID, contextID: request.contextID,
            expectedRevision: request.revision, expectedOriginChatID: request.chatID) else { failed = true; return }
        if selected == model.savedMessagesChatID {
            submittedSavedID = savedForward.requestID
            if savedForward.phase == .queued { dismiss() }
        } else { dismiss() }
    }
}

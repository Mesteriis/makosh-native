import SwiftUI
import MakoshTelegram

public struct TelegramInputAccessoryView: View {
    let title: String
    let detail: String
    let symbol: String
    let cancelLabel: String
    let cancelID: String
    let onClose: () -> Void
    public init(title: String,detail: String,symbol: String,
                cancelLabel: String = "Отменить редактирование",cancelID: String = "telegram.actions.cancelEdit",
                onClose: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.symbol = symbol
        self.cancelLabel = cancelLabel; self.cancelID = cancelID; self.onClose = onClose
    }
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24)
            Rectangle().fill(.tint).frame(width: 2,height: 30)
            VStack(alignment: .leading,spacing: 2) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(.tint).lineLimit(1)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity,alignment: .leading)
            Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help(cancelLabel).accessibilityLabel(cancelLabel)
                .accessibilityIdentifier(cancelID)
        }.padding(.horizontal,16).frame(height: 44)
    }
}

struct TelegramInlineEditView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var controller: TelegramMessageActionsController
    let session: TelegramMessageEditSession
    @State private var editorError: String?
    @State private var rejected = false
    init(model: TelegramModel,session: TelegramMessageEditSession) {
        self.model = model; controller = model.messageActions; self.session = session
    }
    var body: some View {
        VStack(spacing: 0) {
            TelegramInputAccessoryView(title: "Изменить сообщение",detail: session.source.text.isEmpty ? "Сообщение с вложением" : telegramSourcePreview(session.source),symbol: "pencil",onClose: close)
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("telegram.actions.editAccessory")
                .contextMenu {
                    if session.source.metadata.hasMedia {
                        Button(session.captionAboveMedia ? "Переместить подпись вниз" : "Переместить подпись вверх") {
                            _ = model.updateMessageEditCaptionPlacement(!session.captionAboveMedia,
                                sessionID: session.id, revision: session.revision, contextID: session.contextID)
                        }
                        .disabled(controller.isBusy || controller.phase == .uncertain || currentSession?.revision != session.revision)
                        .accessibilityIdentifier("telegram.actions.captionPlacement")
                    }
                }
            HStack(alignment: .bottom,spacing: 12) {
                TelegramRichTextEditor(value: Binding(get: { currentSession?.input.formattedText ?? session.input.formattedText },set: { _ in }),
                    error: $editorError,selection: session.input.selection,inputChanged: { input in
                        _ = model.updateMessageEditInput(input,sessionID: session.id,contextID: session.contextID)
                    },submit: submit)
                    .disabled(controller.isBusy)
                Button(action: submit) { Image(systemName: "checkmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.tint).disabled(!canSubmit)
                    .help("Сохранить изменение").accessibilityLabel("Сохранить изменение")
                    .accessibilityIdentifier("telegram.actions.confirm")
            }.padding(.horizontal,16).padding(.bottom,12)
            if let editorError { Text(editorError).font(.caption).foregroundStyle(.red).padding(.horizontal,16) }
            if rejected { Text("Не удалось начать правку. Введённый текст сохранён.").font(.caption).foregroundStyle(.red) }
        }
    }
    private var currentSession: TelegramMessageEditSession? {
        guard let current = model.messageEditSession,current.id == session.id,
              current.contextID == model.messageActionContextID else { return nil }
        return current
    }
    private var canSubmit: Bool {
        guard model.phase == .ready,!model.isBusy,!model.isRestoringPendingUpload,
              model.pendingUploadRecoveryError == nil,!controller.isBusy,controller.phase != .uncertain,editorError == nil,
              let current = currentSession,model.selectedChatID == current.source.chatID else { return false }
        return current.canSubmit
    }
    private func submit() {
        guard canSubmit,let current = currentSession else { return }
        rejected = !model.submitMessageEdit(sessionID: current.id,revision: current.revision,contextID: current.contextID)
    }
    private func close() {
        guard let current = currentSession else { return }
        if controller.source == current.source { controller.cancel() }
        _ = model.cancelMessageEdit(sessionID: current.id,contextID: current.contextID)
    }
}

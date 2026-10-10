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
    let request: TelegramMessageActionRequest
    let onClose: () -> Void
    @State private var draft: TelegramFormattedText?
    @State private var editorError: String?
    @State private var rejected = false
    @State private var submitted = false
    init(model: TelegramModel,request: TelegramMessageActionRequest,onClose: @escaping () -> Void) {
        self.model = model; controller = model.messageActions; self.request = request; self.onClose = onClose
        _draft = State(initialValue: model.messageFormattedEditDraft(for: request.source))
    }
    var body: some View {
        VStack(spacing: 0) {
            TelegramInputAccessoryView(title: "Изменить сообщение",detail: request.source.text.isEmpty ? "Сообщение с вложением" : telegramSourcePreview(request.source),symbol: "pencil",onClose: close)
            HStack(alignment: .bottom,spacing: 12) {
                if let value = draft {
                    TelegramRichTextEditor(value: Binding(get: { draft ?? value },set: { draft = $0 }),error: $editorError,
                        submit: submit)
                        .disabled(controller.isBusy)
                } else { Text("Форматирование недоступно для безопасной правки.").font(.caption).foregroundStyle(.red) }
                Button(action: submit) { Image(systemName: "checkmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.tint).disabled(!canSubmit)
                    .help("Сохранить изменение").accessibilityLabel("Сохранить изменение")
                    .accessibilityIdentifier("telegram.actions.confirm")
            }.padding(.horizontal,16).padding(.bottom,12)
            if let editorError { Text(editorError).font(.caption).foregroundStyle(.red).padding(.horizontal,16) }
            if rejected { Text("Не удалось начать правку. Введённый текст сохранён.").font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: draft) { _,value in
            if let value { model.saveMessageFormattedEditDraft(value,source: request.source,contextID: request.contextID) }
        }
        .onChange(of: controller.phase) { _,phase in
            if submitted,controller.source == request.source,phase == .applied { onClose() }
        }
        .onChange(of: model.messageActionContextID) { _,_ in onClose() }
        .onChange(of: model.selectedChatID) { _,_ in onClose() }
    }
    private var canSubmit: Bool {
        guard !controller.isBusy,controller.phase != .uncertain,editorError == nil,
              model.messageActionContextID == request.contextID,model.selectedChatID == request.source.chatID,
              let draft,draft.isEditable,draft.text.utf16.count <= request.source.editLimit,
              !draft.text.isEmpty || request.source.metadata.allowsEmptyEdit else { return false }
        return draft != request.source.metadata.formattedText &&
            (request.source.metadata.formattedText != nil || !draft.text.utf8.elementsEqual(request.source.text.utf8) || !draft.entities.isEmpty)
    }
    private func submit() {
        guard canSubmit,let draft else { return }
        submitted = model.performMessageAction(.editFormatted(draft),source: request.source,contextID: request.contextID)
        rejected = !submitted
    }
    private func close() { if submitted { controller.cancel() }; onClose() }
}

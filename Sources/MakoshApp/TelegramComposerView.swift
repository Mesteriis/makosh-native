import SwiftUI
import MakoshTelegram

/// The ordinary composer survives detail-view recreation through TelegramModel.
struct TelegramComposerView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var reply: TelegramComposerReplyController
    @ObservedObject private var actions: TelegramMessageActionsController
    @ObservedObject private var upload: TelegramUploadController
    init(model: TelegramModel) {
        self.model = model; reply = model.composerReply; actions = model.messageActions; upload = model.upload
    }
    var body: some View {
        replyAccessory
        HStack(alignment: .bottom, spacing: 12) {
            TelegramAttachButtons(model: model, replySource: reply.resolved?.source,
                replyContextID: model.messageActionContextID)
                .disabled(reply.preventsSend || actions.isBusy || actions.phase == .uncertain)
            TextField("Сообщение в Telegram", text: $model.draft, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("telegram.composer")
            Button {
                if let resolved = reply.resolved {
                    _ = model.performMessageAction(.reply(model.draft), source: resolved.source,
                        contextID: model.messageActionContextID)
                } else { _ = model.sendMessage(model.draft) }
            } label: { Image(systemName: "paperplane.fill").font(.system(size: 22)).frame(width: 32, height: 32) }
                .buttonStyle(.plain).foregroundStyle(.tint).accessibilityLabel("Отправить")
                .disabled(reply.preventsSend || (model.isSyntheticPreview && reply.resolved == nil) || model.isBusy ||
                    actions.isBusy || actions.phase == .uncertain || upload.phase != .idle ||
                    model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("telegram.send")
        }.padding(.horizontal, 16).padding(.vertical, 10)
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

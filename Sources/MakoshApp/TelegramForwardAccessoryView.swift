import SwiftUI
import MakoshTelegram

struct TelegramForwardAccessoryView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var forward: TelegramComposerForwardController
    @State private var choosingRecipient = false
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
                    Button("Другой получатель…") { choosingRecipient = true }
                }
                .sheet(isPresented: $choosingRecipient) {
                    TelegramForwardRecipientPicker(model: model, intentID: intent.id, contextID: model.messageActionContextID)
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

struct TelegramForwardRecipientPicker: View {
    @ObservedObject var model: TelegramModel
    let intentID: UUID
    let contextID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int64?
    @State private var query = ""
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Переслать сообщение").font(.title2.weight(.semibold))
            TextField("Фильтр загруженных диалогов", text: $query).textFieldStyle(.roundedBorder)
            List(selection: $selected) {
                ForEach(model.forwardDestinations.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { chat in
                    Text(chat.title).tag(chat.id).accessibilityIdentifier("telegram.forward.destination.\(chat.id)")
                }
            }.frame(height: 240)
            if failed { Text("Не удалось выбрать получателя. Пересылка сохранена.").foregroundStyle(.red) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Открыть выбранный диалог") {
                    if let selected, model.moveComposerForward(to: selected, intentID: intentID, contextID: contextID) { dismiss() }
                    else { failed = true }
                }.disabled(selected == nil || model.isForwardComposerLocked).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 520)
    }
}

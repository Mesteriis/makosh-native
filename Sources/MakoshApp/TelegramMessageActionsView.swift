import SwiftUI
import MakoshTelegram

struct TelegramMessageActionRequest: Identifiable {
    enum Mode { case reply, edit, forward, delete }
    let id = UUID()
    let source: TelegramMessageActionSource
    let author: String
    let contextID: UUID
    let mode: Mode
}

struct TelegramMessageActionsItems: View {
    let source: TelegramMessageActionSource
    let disabled: Bool
    let choose: (TelegramMessageActionRequest.Mode) -> Void
    var body: some View {
        Group {
            Button("Ответить", systemImage: "arrowshape.turn.up.left") { choose(.reply) }.disabled(!source.canReply)
            Button("Изменить", systemImage: "pencil") { choose(.edit) }.disabled(!source.canEdit)
            Button("Переслать…", systemImage: "arrowshape.turn.up.right") { choose(.forward) }.disabled(!source.canForward)
            Divider()
            Button("Удалить…", systemImage: "trash", role: .destructive) { choose(.delete) }
                .disabled(!source.canDeleteLocally && !source.canDeleteForEveryone)
        }.disabled(disabled)
    }
}

struct TelegramMessageActionsStatus: View {
    @ObservedObject var controller: TelegramMessageActionsController
    let synthetic: Bool
    var body: some View {
        if controller.phase != .idle {
            HStack(alignment: .top) {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Text(status).font(.caption).textSelection(.enabled)
                Spacer()
                if controller.isBusy { Button("Прекратить ожидание", action: controller.cancel).controlSize(.small) }
            }.padding(12).background(.secondary.opacity(0.06)).accessibilityIdentifier("telegram.actions.status")
        }
    }
    private var status: String {
        let prefix = synthetic ? "Симуляция: " : ""
        switch controller.phase {
        case .idle: return ""
        case .validating: return prefix + "Проверяем исходное сообщение и доступность действия…"
        case .committing: return prefix + "Выполняем действие…"
        case .queued: return prefix + "Действие принято локальной очередью. Выполнение на сервере ещё не подтверждено."
        case .applied: return prefix + "Изменение текста подтверждено."
        case .rejected: return prefix + "Действие отклонено: сообщение изменилось или операция недоступна. Введённый текст сохранён."
        case .uncertain: return prefix + "Результат неизвестен. Автоматический повтор отключён. Проверьте историю Telegram перед новым подключением."
        }
    }
}

struct TelegramMessageActionSheet: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var controller: TelegramMessageActionsController
    let request: TelegramMessageActionRequest
    @Environment(\.dismiss) private var dismiss
    @State private var destination: Int64?
    @State private var destinationQuery = ""
    @State private var deleteForEveryone: Bool?
    @State private var submitted = false
    @State private var validationFailed = false
    init(model: TelegramModel, request: TelegramMessageActionRequest) {
        self.model = model; self.controller = model.messageActions; self.request = request
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(request.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Group {
                if request.source.canCopy {
                    Text(request.source.text.isEmpty ? "Сообщение с вложением" : telegramSourcePreview(request.source)).textSelection(.enabled)
                } else {
                    Text(request.source.text.isEmpty ? "Сообщение с вложением" : telegramSourcePreview(request.source)).textSelection(.disabled)
                }
            }.lineLimit(4).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            switch request.mode {
            case .edit: EmptyView()
            case .forward:
                TextField("Фильтр загруженных диалогов", text: $destinationQuery).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("telegram.actions.destinationFilter")
                List(selection: $destination) {
                    ForEach(model.forwardDestinations.filter { destinationQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(destinationQuery) }) { chat in
                        Text(chat.title).tag(chat.id).accessibilityIdentifier("telegram.actions.destination.\(chat.id)")
                    }
                }.frame(height: 200).disabled(controller.isBusy).accessibilityIdentifier("telegram.actions.destinations")
                if let selected = model.forwardDestinations.first(where: { $0.id == destination }) {
                    Text("Получатель: \(selected.title)").font(.callout.weight(.semibold))
                } else { Text("Выберите получателя. Здесь доступны уже загруженные диалоги текущего аккаунта.").font(.caption).foregroundStyle(.secondary) }
            case .delete:
                if request.source.canDeleteLocally {
                    Button { deleteForEveryone = false } label: { Label("Удалить только у меня", systemImage: deleteForEveryone == false ? "largecircle.fill.circle" : "circle") }
                        .accessibilityIdentifier("telegram.actions.deleteLocal")
                }
                if request.source.canDeleteForEveryone {
                    Button { deleteForEveryone = true } label: { Label("Удалить для всех в Telegram", systemImage: deleteForEveryone == true ? "largecircle.fill.circle" : "circle") }
                        .accessibilityIdentifier("telegram.actions.deleteEveryone")
                }
                if let deleteForEveryone {
                    Text(deleteForEveryone ? "Выбрано: для всех в Telegram" : "Выбрано: только у меня")
                        .font(.callout.weight(.semibold)).accessibilityIdentifier("telegram.actions.deleteScope")
                }
                Text("Ранее сохранённые версии и копии файлов останутся в Макоше.").font(.callout)
                    .accessibilityIdentifier("telegram.actions.retentionNotice")
            case .reply: EmptyView()
            }
            if validationFailed { Text("Не удалось начать действие. Проверьте выбранный диалог и подключение.").foregroundStyle(.red).font(.caption) }
            if submitted { TelegramMessageActionsStatus(controller: controller, synthetic: model.isSyntheticPreview) }
            HStack {
                Button("Отмена") { if submitted { controller.cancel() }; dismiss() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("telegram.actions.cancel")
                Spacer()
                Button(confirmTitle, role: request.mode == .delete ? .destructive : nil, action: submit)
                    .buttonStyle(.borderedProminent).disabled(!canSubmit)
                    .accessibilityIdentifier("telegram.actions.confirm")
            }
        }.padding(24).frame(width: 520)
            .interactiveDismissDisabled(controller.isBusy)
            .onChange(of: controller.phase) { _, phase in
                if submitted, controller.source == request.source, phase == .queued || phase == .applied { dismiss() }
            }
            .onChange(of: model.messageActionContextID) { _, _ in dismiss() }
    }
    private var title: String {
        switch request.mode { case .edit: "Изменить сообщение"; case .forward: "Переслать сообщение"; case .delete: "Удалить в Telegram"; case .reply: "Ответить" }
    }
    private var confirmTitle: String {
        switch request.mode {
        case .edit: return "Сохранить изменение"
        case .forward: return "Переслать выбранному получателю"
        case .delete: return deleteForEveryone.map { $0 ? "Удалить для всех в Telegram" : "Удалить только у меня" } ?? "Удалить в Telegram"
        case .reply: return "Ответить"
        }
    }
    private var canSubmit: Bool {
        guard !controller.isBusy, controller.phase != .uncertain,
              model.messageActionContextID == request.contextID else { return false }
        switch request.mode {
        case .edit: return false
        case .forward: return destination != nil
        case .delete: return deleteForEveryone != nil
        case .reply: return false
        }
    }
    private func submit() {
        let action: TelegramMessageAction
        switch request.mode {
        case .edit: return
        case .forward: guard let destination else { return }; action = .forward(destinationChatID: destination)
        case .delete: guard let deleteForEveryone else { return }; action = .delete(forEveryone: deleteForEveryone)
        case .reply: return
        }
        submitted = model.performMessageAction(action, source: request.source, contextID: request.contextID)
        validationFailed = !submitted
    }
}

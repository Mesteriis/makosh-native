import SwiftUI
import MakoshTelegram

struct TelegramMessageActionRequest: Identifiable {
    enum Mode { case reply, edit, forward, delete }
    let id = UUID()
    let source: TelegramMessageActionSource
    let author: String
    let contextID: UUID
    let mode: Mode
    var selection: TelegramMessageSelectionSession? = nil
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
    @ObservedObject private var selection: TelegramMessageSelectionController
    @ObservedObject private var selectedDelete: TelegramSelectedMessagesDeleteController
    @ObservedObject private var savedForward: TelegramSavedMessagesForwardController
    let request: TelegramMessageActionRequest
    @Environment(\.dismiss) private var dismiss
    @State private var destination: Int64?
    @State private var destinationQuery = ""
    @State private var deleteForEveryone: Bool?
    @State private var submitted = false
    @State private var submittedSavedID: UUID?
    @State private var validationFailed = false
    init(model: TelegramModel, request: TelegramMessageActionRequest) {
        self.model = model; self.controller = model.messageActions; self.request = request
        self.selection = model.messageSelection
        self.selectedDelete = model.selectedMessagesDelete
        self.savedForward = model.savedMessagesForward
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(request.selection.map { "Выбрано сообщений: \($0.count)" } ?? request.author)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                TextField("Найти получателя", text: $destinationQuery).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("telegram.actions.destinationFilter")
                List(selection: $destination) {
                    ForEach(model.messageActionForwardDestinations.filter { destinationQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(destinationQuery) }) { chat in
                        if chat.id == model.savedMessagesChatID {
                            Button { destination = chat.id; submit() } label: {
                                Label(chat.title, systemImage: "bookmark")
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                                .buttonStyle(.plain).tag(chat.id).disabled(!canChooseSaved)
                                .help("Сразу переслать в Избранное")
                                .accessibilityIdentifier("telegram.actions.destination.\(chat.id)")
                        } else {
                            Text(chat.title).tag(chat.id).accessibilityIdentifier("telegram.actions.destination.\(chat.id)")
                        }
                    }
                }.frame(height: 200).disabled(controller.isBusy || submittedSavedID != nil).accessibilityIdentifier("telegram.actions.destinations")
                if let selected = model.messageActionForwardDestinations.first(where: { $0.id == destination }) {
                    Text("Получатель: \(selected.title)").font(.callout.weight(.semibold))
                } else { Text("Нажмите «Избранное», чтобы переслать сразу, или выберите другой диалог.").font(.caption).foregroundStyle(.secondary) }
            case .delete:
                if request.selection?.canDeleteLocally ?? request.source.canDeleteLocally {
                    Button { deleteForEveryone = false } label: { Label("Удалить только у меня", systemImage: deleteForEveryone == false ? "largecircle.fill.circle" : "circle") }
                        .accessibilityIdentifier("telegram.actions.deleteLocal")
                }
                if request.selection?.canDeleteForEveryone ?? (request.source.chatID != request.source.accountID && request.source.canDeleteForEveryone) {
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
            if submitted {
                if submittedSavedID != nil {
                    TelegramSavedMessagesForwardStatus(controller: savedForward, synthetic: model.isSyntheticPreview)
                } else if request.mode == .delete && request.selection != nil {
                    TelegramSelectedMessagesDeleteStatus(controller: selectedDelete, synthetic: model.isSyntheticPreview)
                } else { TelegramMessageActionsStatus(controller: controller, synthetic: model.isSyntheticPreview) }
            }
            HStack {
                Button("Отмена") {
                    if submitted {
                        if submittedSavedID != nil { savedForward.cancel() }
                        else if request.mode == .delete && request.selection != nil { selectedDelete.cancel() }
                        else { controller.cancel() }
                    }
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("telegram.actions.cancel")
                Spacer()
                Button(confirmTitle, role: request.mode == .delete ? .destructive : nil, action: submit)
                    .buttonStyle(.borderedProminent).disabled(!canSubmit)
                    .accessibilityIdentifier("telegram.actions.confirm")
            }
        }.padding(24).frame(width: 520)
            .interactiveDismissDisabled(controller.isBusy || selectedDelete.isBusy || submittedSavedID != nil && savedForward.isBusy)
            .onChange(of: controller.phase) { _, phase in
                if submitted, controller.source == request.source, phase == .queued || phase == .applied { dismiss() }
            }
            .onChange(of: model.messageActionContextID) { _, _ in dismiss() }
            .onChange(of: selectedDelete.phase) { _, phase in
                if submitted, phase == .queued, let selected = request.selection,
                   selectedDelete.request?.sessionID == selected.id, selectedDelete.request?.revision == selected.revision,
                   selectedDelete.request?.contextID == request.contextID { dismiss() }
            }
            .onChange(of: savedForward.phase) { _, phase in
                if submitted, phase == .queued, submittedSavedID == savedForward.requestID,
                   model.messageActionContextID == request.contextID { dismiss() }
            }
    }
    private var title: String {
        switch request.mode {
        case .edit: "Изменить сообщение"
        case .forward: request.selection == nil ? "Переслать сообщение" : "Переслать выбранные сообщения"
        case .delete: "Удалить в Telegram"
        case .reply: "Ответить"
        }
    }
    private var confirmTitle: String {
        switch request.mode {
        case .edit: return "Сохранить изменение"
        case .forward: return destination != nil && destination == model.savedMessagesChatID ? "Переслать в Избранное" : "Открыть выбранный диалог"
        case .delete: return deleteForEveryone.map { $0 ? "Удалить для всех в Telegram" : "Удалить только у меня" } ?? "Удалить в Telegram"
        case .reply: return "Ответить"
        }
    }
    private var canSubmit: Bool {
        guard !controller.isBusy, controller.phase != .uncertain, !model.selectedMessagesDeletionBlocksActions,
              model.messageActionContextID == request.contextID else { return false }
        switch request.mode {
        case .edit: return false
        case .forward:
            if let selection = request.selection {
                guard self.selection.session?.id == selection.id,
                      self.selection.session?.revision == selection.revision,
                      self.selection.session?.canForward == true else { return false }
            }
            return destination != nil && (destination != model.savedMessagesChatID || canChooseSaved)
        case .delete:
            guard let deleteForEveryone else { return false }
            if let selected = request.selection {
                guard !selection.isResolvingRange, let current = selection.session,
                      current.id == selected.id, current.revision == selected.revision else { return false }
                return deleteForEveryone ? current.canDeleteForEveryone : current.canDeleteLocally
            }
            return deleteForEveryone ? request.source.canDeleteForEveryone : request.source.canDeleteLocally
        case .reply: return false
        }
    }
    private var canChooseSaved: Bool {
        guard !submitted, !savedForward.isBusy, savedForward.phase != .uncertain,
              !controller.isBusy, controller.phase != .uncertain, !model.selectedMessagesDeletionBlocksActions,
              model.messageActionContextID == request.contextID, !selection.isResolvingRange else { return false }
        if let selected = request.selection {
            return selection.session?.id == selected.id && selection.session?.revision == selected.revision && selection.session?.canForward == true
        }
        return request.source.canForward
    }
    private func submit() {
        let action: TelegramMessageAction
        switch request.mode {
        case .edit: return
        case .forward:
            guard let destination else { return }
            if destination == model.savedMessagesChatID {
                guard canChooseSaved else { return }
                if let selected = request.selection {
                    submitted = model.forwardSelectedMessagesToSaved(sessionID: selected.id, contextID: request.contextID, expectedRevision: selected.revision)
                } else { submitted = model.forwardMessageToSaved(source: request.source, contextID: request.contextID) }
                validationFailed = !submitted
                if submitted {
                    submittedSavedID = savedForward.requestID
                    if savedForward.phase == .queued { dismiss() }
                }
                return
            }
            let staged: Bool
            if let selection = request.selection {
                staged = model.stageSelectedMessagesForward(destinationChatID: destination, sessionID: selection.id,
                    contextID: request.contextID, expectedRevision: selection.revision)
            } else {
                staged = model.stageMessageForward(source: request.source, destinationChatID: destination, contextID: request.contextID)
            }
            validationFailed = !staged
            if staged { dismiss() }
            return
        case .delete:
            guard let deleteForEveryone else { return }
            if let selected = request.selection {
                submitted = model.deleteSelectedMessages(forEveryone: deleteForEveryone, sessionID: selected.id,
                    contextID: request.contextID, expectedRevision: selected.revision)
                validationFailed = !submitted
                // Preview providers can finish before onChange sees submitted=true.
                if submitted, selectedDelete.phase == .queued { dismiss() }
                return
            }
            action = .delete(forEveryone: deleteForEveryone)
        case .reply: return
        }
        submitted = model.performMessageAction(action, source: request.source, contextID: request.contextID)
        validationFailed = !submitted
    }
}

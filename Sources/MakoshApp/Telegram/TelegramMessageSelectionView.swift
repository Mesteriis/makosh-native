import SwiftUI
import MakoshTelegram

struct TelegramMessageSelectionPanel: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var selection: TelegramMessageSelectionController
    @ObservedObject private var copy: TelegramSelectedMessagesCopyController
    @ObservedObject private var deletion: TelegramSelectedMessagesDeleteController
    @FocusState private var selectionFocused: Bool
    let copyCommand: (() -> Void)?
    let forward: (TelegramMessageSelectionSession) -> Void
    let delete: (TelegramMessageSelectionSession) -> Void
    init(model: TelegramModel, copyCommand: (() -> Void)?, forward: @escaping (TelegramMessageSelectionSession) -> Void,
         delete: @escaping (TelegramMessageSelectionSession) -> Void) {
        self.model = model; selection = model.messageSelection; self.forward = forward; self.delete = delete
        copy = model.selectedMessagesCopy; deletion = model.selectedMessagesDelete
        self.copyCommand = copyCommand
    }
    var body: some View {
        if let session = selection.session {
            VStack(spacing: 8) {
                HStack {
                    Button(role: .destructive) { delete(session) } label: { Image(systemName: "trash").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(.red).accessibilityLabel("Удалить выбранные сообщения…")
                        .accessibilityIdentifier("telegram.selection.delete")
                        .disabled(selection.isResolvingRange || (!session.canDeleteLocally && !session.canDeleteForEveryone) || blocked || copy.isBusy)
                    Spacer()
                    Text("Выбрано: \(session.count)").font(.callout.weight(.medium))
                        .accessibilityIdentifier("telegram.selection.count")
                    Button { model.cancelMessageSelection(sessionID: session.id, contextID: session.contextID) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Отменить выбор сообщений")
                        .accessibilityIdentifier("telegram.selection.cancel").disabled(model.selectedMessagesDeletionBlocksActions)
                    Spacer()
                    Button { forward(session) } label: { Image(systemName: "arrowshape.turn.up.right").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).accessibilityLabel("Переслать выбранные сообщения")
                        .accessibilityIdentifier("telegram.selection.forward")
                        .disabled(selection.isResolvingRange || !session.canForward || blocked)
                }
                if let error = copy.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("telegram.selection.copyError")
                } else if copy.isBusy {
                    Text("Копируем выбранные сообщения…").font(.caption).foregroundStyle(.secondary)
                } else if selection.isResolvingRange {
                    Text("Выбираем диапазон…").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("telegram.selection.resolving")
                } else if let error = selection.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("telegram.selection.error")
                } else if session.count > 0 && !session.canForward {
                    Text("Некоторые выбранные сообщения нельзя переслать. Снимите с них выбор.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
                .focusable().focused($selectionFocused).focusEffectDisabled()
                .focusedSceneValue(\.copyTelegramSelection,
                    session.canCopy && !selection.isResolvingRange && !blocked && !copy.isBusy ? copyCommand : nil)
                .onAppear { selectionFocused = true }
        }
    }
    private var blocked: Bool { model.selectedMessagesDeletionBlocksActions || model.isBusy || model.isRestoringComposerDraft || model.composerDraftRecoveryError != nil }
}

struct TelegramSelectedMessagesDeleteStatus: View {
    @ObservedObject var controller: TelegramSelectedMessagesDeleteController
    let synthetic: Bool
    var body: some View {
        if controller.phase != .idle {
            HStack(alignment: .top) {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Text((synthetic ? "Симуляция: " : "") + status).font(.caption).textSelection(.enabled)
                Spacer()
                if controller.isBusy { Button("Прекратить ожидание", action: controller.cancel).controlSize(.small) }
            }.padding(12).accessibilityIdentifier("telegram.selection.deleteStatus")
        }
    }
    private var status: String {
        switch controller.phase {
        case .idle: ""
        case .validating: "Проверяем все выбранные сообщения…"
        case .committing: "Удаляем выбранные сообщения в Telegram…"
        case .queued: "Удаление принято локальной очередью. Выполнение на сервере ещё не подтверждено. Сохранённые версии и файлы остаются в Макоше."
        case .rejected: "Удаление отклонено: одно из сообщений изменилось или операция недоступна. Выбранный набор сохранён."
        case .uncertain, .applied: "Результат удаления неизвестен. Автоматический повтор отключён. Проверьте историю Telegram перед новым подключением."
        }
    }
}

struct TelegramSelectableHistoryRow<Content: View>: View {
    @ObservedObject var selection: TelegramMessageSelectionController
    let message: TelegramMessage
    let source: TelegramMessageActionSource?
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        if selection.session != nil {
            let selected = source.map(selection.contains) ?? false
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary).frame(width: 24)
                    content().allowsHitTesting(false).accessibilityHidden(true)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .background(selected ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .disabled(!selected && (source.map { !TelegramComposerForwardSource(source: $0).isValid } ?? true))
                .accessibilityLabel(TelegramMessagePresentation.selectionLabel(for: message))
                .accessibilityValue(selected ? "Выбрано" : "Не выбрано")
                .accessibilityIdentifier("telegram.selection.message.\(message.id)")
        } else {
            content()
        }
    }
}

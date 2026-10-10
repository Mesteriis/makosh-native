import SwiftUI
import MakoshTelegram

struct TelegramMessageSelectionPanel: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var selection: TelegramMessageSelectionController
    let forward: (TelegramMessageSelectionSession) -> Void
    init(model: TelegramModel, forward: @escaping (TelegramMessageSelectionSession) -> Void) {
        self.model = model; selection = model.messageSelection; self.forward = forward
    }
    var body: some View {
        if let session = selection.session {
            VStack(spacing: 8) {
                HStack {
                    Button("Отмена") { model.cancelMessageSelection(sessionID: session.id, contextID: session.contextID) }
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("telegram.selection.cancel")
                    Spacer()
                    Text("Выбрано: \(session.count)").font(.callout.weight(.medium))
                        .accessibilityIdentifier("telegram.selection.count")
                    Spacer()
                    Button { forward(session) } label: { Image(systemName: "arrowshape.turn.up.right").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).accessibilityLabel("Переслать выбранные сообщения")
                        .accessibilityIdentifier("telegram.selection.forward")
                        .disabled(!session.canForward || model.isBusy || model.isRestoringComposerDraft || model.composerDraftRecoveryError != nil)
                }
                if let error = selection.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("telegram.selection.error")
                } else if session.count > 0 && !session.canForward {
                    Text("Некоторые выбранные сообщения нельзя переслать. Снимите с них выбор.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
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
                .disabled(source.map { !TelegramComposerForwardSource(source: $0).isValid } ?? true)
                .accessibilityLabel(TelegramMessagePresentation.selectionLabel(for: message))
                .accessibilityValue(selected ? "Выбрано" : "Не выбрано")
                .accessibilityIdentifier("telegram.selection.message.\(message.id)")
        } else {
            content()
        }
    }
}

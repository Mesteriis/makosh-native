import MakoshAI
import MakoshCore
import SwiftUI

/// The AI beside an open chat: that chat's conversations, with the chat
/// attached as context by default.
struct AIChatPanelView: View {
    @ObservedObject var model: AIWorkspaceModel
    let search: AIContextSearch
    let anchor: AIContextCard
    let openCard: (AIContextCard) -> Void
    let openInSection: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("ИИ", systemImage: "sparkles").font(.headline)
                Spacer()
                Menu {
                    ForEach(model.visibleConversations) { conversation in
                        Button(conversation.title.isEmpty ? "Новая беседа" : conversation.title) {
                            Task { await model.select(conversation.id) }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton).fixedSize().help("Беседы этого чата")
                .disabled(model.visibleConversations.count < 2).accessibilityIdentifier("ai.panel.conversations")
                Button {
                    Task { await model.newConversation() }
                } label: {
                    Image(systemName: "square.and.pencil")
                }.buttonStyle(.plain).help("Новая беседа о чате").accessibilityIdentifier("ai.panel.new")
                Button(action: openInSection) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help("Открыть в разделе «ИИ»").accessibilityIdentifier("ai.panel.expand")
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Закрыть панель ИИ").accessibilityIdentifier("ai.panel.close")
            }
            .padding(.horizontal, 12).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
            Divider()
            if model.roles[.chat] == nil {
                ContentUnavailableView(
                    "Модель не назначена", systemImage: "sparkles",
                    description: Text("Назначьте модель для роли «Беседа» в Настройки → ИИ."))
            } else {
                AIConversationView(model: model, contextSearch: search, openCard: openCard)
            }
        }
        .frame(minWidth: 300, idealWidth: 360, maxWidth: 440, maxHeight: .infinity)
        .background(WorkspaceStyle.base)
        .task(id: anchor.id) { await model.open(anchor: anchor) }
        .accessibilityIdentifier("ai.panel")
    }
}

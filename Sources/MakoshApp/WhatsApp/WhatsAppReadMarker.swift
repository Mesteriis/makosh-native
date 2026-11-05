import MakoshWhatsApp
import SwiftUI

/// Marks the open WhatsApp chat read while its window is key and visible,
/// and again when a newer incoming message appears.
struct WhatsAppReadMarker: ViewModifier {
    @ObservedObject var model: WhatsAppWorkspaceModel
    @State private var eligibility: (@MainActor () -> Bool)?
    @State private var generation = UUID()

    func body(content: Content) -> some View {
        content
            .background {
                HistoryReadWindowGate(publicationID: generation) { check in
                    eligibility = check
                    mark()
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .onChange(of: model.selectedChatID) { _, _ in
                generation = UUID()
                mark()
            }
            .onChange(of: model.messages.first { !$0.outgoing }?.id) { _, _ in mark() }
            .onChange(of: model.chats.first { $0.id == model.selectedChatID }?.unread) { _, _ in mark() }
            .onDisappear { eligibility = nil }
    }

    private func mark() {
        let active = eligibility?() == true
        Task { await model.markVisibleRead(windowIsActive: active) }
    }
}

import SwiftUI
import MakoshTelegram

struct TelegramChatListAvatar: View {
    let chat: TelegramChat
    @ObservedObject var store: TelegramAvatarStore
    let isSelected: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()
    @State private var clockRevision = UUID()

    private struct Refresh: Equatable {
        let presence: TelegramChatPresence?
        let clockRevision: UUID
    }

    private var presence: TelegramChatPresence? { chat.presence?.peerID == chat.id ? chat.presence : nil }

    var body: some View {
        TelegramChatAvatar(title: chat.title, peerID: chat.id, store: store, size: 50)
            .overlay(alignment: .bottomTrailing) {
                if presence?.isOnline(now: now) == true {
                    Circle().fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .overlay { Circle().fill(isSelected ? Color.white : Color.accentColor).padding(2) }
                        .frame(width: 12, height: 12).padding(.trailing, 3)
                        .accessibilityLabel("В сети").accessibilityIdentifier("telegram.chat.online.\(chat.id)")
                }
            }
            .task(id: Refresh(presence: presence, clockRevision: clockRevision)) {
                now = Date()
                guard let presence else { return }
                while presence.isOnline(now: now) {
                    let delay = min(3_600, max(0.05, presence.expiresAt.timeIntervalSinceNow))
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard !Task.isCancelled else { return }
                    now = Date()
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refreshClock() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in refreshClock() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in refreshClock() }
    }

    private func refreshClock() { now = Date(); clockRevision = UUID() }
}

import SwiftUI
import MakoshTelegram

struct TelegramPeerStatusView: View {
    let status: TelegramPeerStatus
    let identifier: String
    @State private var now = Date()
    var body: some View {
        let value = status.presentation(now: now)
        Text(value.text).font(.caption).foregroundStyle(value.isOnline ? Color.accentColor : .secondary)
            .lineLimit(1).accessibilityIdentifier(identifier)
            .task(id: status) {
                now = Date()
                while let next = status.presentation(now: now).nextRefresh {
                    let delay = min(3_600, max(0.05, next.timeIntervalSinceNow))
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard !Task.isCancelled else { return }
                    now = Date()
                }
            }
    }
}

struct TelegramChatAvatar: View {
    let title: String
    let peerID: Int64
    @ObservedObject var store: TelegramAvatarStore
    let size: CGFloat
    @State private var loaded: Loaded?
    private struct Request: Equatable {
        let context: UUID
        let key: TelegramAvatarKey
    }
    private struct Loaded {
        let request: Request
        let preview: TelegramImagePreview
    }
    private var request: Request {
        Request(context: store.contextID, key: TelegramAvatarKey(peerID: peerID, size: size > 50 ? .large : .small))
    }
    private var initials: String {
        title.split(whereSeparator: { $0.isWhitespace }).prefix(2)
            .compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
    var body: some View {
        Group {
            if let loaded, loaded.request == request {
                Image(decorative: loaded.preview.image, scale: 1).resizable().scaledToFill()
            } else {
                Text(initials).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor.opacity(0.14))
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
            .task(id: request) {
                let current = request
                loaded = nil
                for await image in store.images(for: current.key) {
                    guard !Task.isCancelled, store.contextID == current.context else { return }
                    loaded = image.map { Loaded(request: current, preview: $0) }
                }
            }
    }
}

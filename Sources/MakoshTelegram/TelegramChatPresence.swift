import Foundation
import TelegramCore
import Postbox

/// A list observation belongs to one selected account and one native chat.
/// This is separate from the profile/header's textual status policy.
public struct TelegramChatPresence: Equatable, Sendable {
    public let accountID: Int64
    public let peerID: Int64
    public let expiresAt: Date

    public func isOnline(now: Date) -> Bool {
        now.timeIntervalSince1970.isFinite && expiresAt.timeIntervalSince1970.isFinite && now < expiresAt
    }
}

func telegramChatPresence(presence: PeerPresence?, accountID: Int64, peerID: Int64,
                          serverTimeOffset: TimeInterval) -> TelegramChatPresence? {
    let serviceID = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(777000)).toInt64()
    guard peerID != accountID, peerID != serviceID,
          let presence = presence as? TelegramUserPresence,
          serverTimeOffset.isFinite, abs(serverTimeOffset) <= Double(Int32.max) else { return nil }
    let timestamp: Double
    switch presence.status {
    case let .present(until): timestamp = Double(until)
    case .recently: timestamp = Double(presence.lastActivity) + 30
    case .none, .lastWeek, .lastMonth: return nil
    }
    // The reference compares inclusive integer seconds and truncates the offset.
    // Expire at the following device second; arithmetic stays outside Int32.
    let expiry = timestamp - serverTimeOffset.rounded(.towardZero) + 1
    return TelegramChatPresence(accountID: accountID, peerID: peerID,
        expiresAt: Date(timeIntervalSince1970: expiry))
}

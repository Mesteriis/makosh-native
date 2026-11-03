import Foundation
import TelegramCore

public enum TelegramMessageFee: Equatable, Sendable {
    case free
    case stars(Int64)
    case unavailable
}

public struct TelegramSecretChatVerification: Equatable, Sendable {
    public let sha1: Data
    public let sha256: Data
    public init?(sha1: Data, sha256: Data) {
        guard sha1.count == 20, sha256.count == 32 else { return nil }
        self.sha1 = sha1; self.sha256 = sha256
    }
    public var hexLines: [String] {
        [sha1.subdata(in: 0..<8), sha1.subdata(in: 8..<16),
            sha256.subdata(in: 0..<8), sha256.subdata(in: 8..<16)].map {
            $0.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }
}

public struct TelegramSecretConversation: Equatable, Sendable {
    public enum State: Equatable, Sendable { case handshake, active, terminated }
    public let regularPeerID: Int64
    public let participantTitle: String
    public let state: State
    public let verification: TelegramSecretChatVerification?
}

public struct TelegramConversationCapabilities: Equatable, Sendable {
    public let accountID: Int64
    public let chatID: Int64
    public let messageFee: TelegramMessageFee
    public let secret: TelegramSecretConversation?
}

public enum TelegramConversationCapabilitiesError: Error, Equatable, Sendable {
    case unavailable, incompatible, unsupported
}

public struct TelegramPaidMediaState: Equatable, Sendable {
    public enum Access: Equatable, Sendable { case locked, full, mixed }
    public let amount: Int64
    public let itemCount: Int
    public let access: Access
}

func telegramPaidMediaState(_ media: TelegramMediaPaidContent) -> TelegramPaidMediaState? {
    guard media.amount > 0, !media.extendedMedia.isEmpty else { return nil }
    var full = 0
    for item in media.extendedMedia { if case .full = item { full += 1 } }
    let access: TelegramPaidMediaState.Access = full == 0 ? .locked
        : (full == media.extendedMedia.count ? .full : .mixed)
    return .init(amount: media.amount, itemCount: media.extendedMedia.count, access: access)
}

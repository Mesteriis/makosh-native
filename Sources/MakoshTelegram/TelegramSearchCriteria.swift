import Foundation
import TelegramCore
import Postbox

public enum TelegramSearchMediaFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
    case all, photoVideo, photos, videos, links, music, voiceOrVideo, voice, roundVideo, gifs, files

    public var id: String { rawValue }

    public var tags: MessageTags? {
        switch self {
        case .all: nil
        case .photoVideo: .photoOrVideo
        case .photos: .photo
        case .videos: .video
        case .links: .webPage
        case .music: .music
        case .voiceOrVideo: .voiceOrInstantVideo
        case .voice: .voice
        case .roundVideo: .roundVideo
        case .gifs: .gif
        case .files: .file
        }
    }
}

public enum TelegramSearchScope: String, CaseIterable, Identifiable, Equatable, Sendable {
    case all, privateChats, groups, channels

    public var id: String { rawValue }

    public var nativeScope: TelegramSearchPeersScope {
        switch self {
        case .all: .everywhere
        case .privateChats: .privateChats
        case .groups: .groups
        case .channels: .channels
        }
    }
}

/// Immutable search inputs, independent of account and pagination state.
public struct TelegramSearchCriteria: Equatable, Sendable {
    public let query: String
    public let senderID: Int64?
    public let media: TelegramSearchMediaFilter
    public let scope: TelegramSearchScope
    public let chatID: Int64?
    public let threadID: Int64?

    public init(query: String = "", senderID: Int64? = nil,
                media: TelegramSearchMediaFilter = .all, scope: TelegramSearchScope = .all,
                chatID: Int64? = nil, threadID: Int64? = nil) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senderID = senderID
        self.media = media
        self.scope = scope
        self.chatID = chatID
        self.threadID = threadID
    }

    public var isValid: Bool {
        guard chatID != nil || (senderID == nil && threadID == nil) else { return false }
        if let chatID, !Self.isSearchablePeerID(chatID, allowsSecretChat: true) { return false }
        if let senderID, !Self.isSearchablePeerID(senderID, allowsSecretChat: false) { return false }
        if let threadID, threadID <= 0 || Int32(exactly: threadID) == nil { return false }
        return true
    }

    /// Choosing a peer or topic is context; an otherwise empty search stays idle.
    public var isActive: Bool {
        isValid && (!query.isEmpty || senderID != nil || media != .all
            || (chatID == nil && scope != .all))
    }

    public var nativeLocation: SearchMessagesLocation? {
        guard isValid else { return nil }
        if let chatID {
            return .peer(peerId: PeerId(chatID), fromId: senderID.map(PeerId.init), tags: media.tags,
                         reactions: nil, threadId: threadID, minDate: nil, maxDate: nil)
        }
        return .general(scope: scope.nativeScope, tags: media.tags, minDate: nil, maxDate: nil)
    }

    private static func isSearchablePeerID(_ value: Int64, allowsSecretChat: Bool) -> Bool {
        guard isCanonicalPeerID(value) else { return false }
        let peerID = PeerId(value)
        let id = peerID.id._internalGetInt64Value()
        switch peerID.namespace {
        case Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel:
            return id > 0
        case Namespaces.Peer.SecretChat:
            return allowsSecretChat && id != 0 && Int32(exactly: id) != nil
        default:
            return false
        }
    }

    private static func isCanonicalPeerID(_ value: Int64) -> Bool {
        let bits = UInt64(bitPattern: value)
        // Postbox's legacy Empty sentinel is the sole encoding for namespace 7 / id 0.
        if bits == 0x7fffffff00000000 { return true }
        return bits >> 59 == 0 && bits != 0x0000000700000000
    }
}

import Foundation
import Postbox
import TelegramCore

public struct TelegramComposerForwardSource: Codable, Equatable, Sendable {
    public let chatID: Int64
    public let peerID: Int64
    public let namespace: Int32
    public let messageID: Int32
    public let threadID: Int64?
    public let fingerprint: String
    public init(chatID: Int64, peerID: Int64, namespace: Int32, messageID: Int32, threadID: Int64? = nil, fingerprint: String) {
        self.chatID = chatID; self.peerID = peerID; self.namespace = namespace
        self.messageID = messageID; self.threadID = threadID; self.fingerprint = fingerprint
    }
    public init(source: TelegramMessageActionSource) {
        self.init(chatID: source.chatID, peerID: source.peerID, namespace: source.namespace,
                  messageID: source.messageID, threadID: source.threadID, fingerprint: source.fingerprint)
    }
    public var isValid: Bool {
        let peer = PeerId(peerID), chat = PeerId(chatID)
        let clouds = [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel]
        return peer.id._internalGetInt64Value() > 0 && chat.id._internalGetInt64Value() > 0 &&
            clouds.contains(peer.namespace) && clouds.contains(chat.namespace) && namespace == Namespaces.Message.Cloud && messageID > 0 &&
            !fingerprint.isEmpty && fingerprint.utf8.count <= 4096 && (threadID.map { $0 > 0 } ?? true)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chatID == rhs.chatID && lhs.peerID == rhs.peerID && lhs.namespace == rhs.namespace &&
        lhs.messageID == rhs.messageID && lhs.threadID == rhs.threadID && lhs.fingerprint.utf8.elementsEqual(rhs.fingerprint.utf8)
    }
}
public struct TelegramForwardQueueID: Codable, Equatable, Sendable {
    public let peerID: Int64
    public let namespace: Int32
    public let messageID: Int32
    public init(peerID: Int64, namespace: Int32, messageID: Int32) {
        self.peerID = peerID; self.namespace = namespace; self.messageID = messageID
    }
}
public enum TelegramComposerForwardDisposition: Codable, Equatable, Sendable {
    case prepared, submissionStarted, accepted([TelegramForwardQueueID])
}
public enum TelegramForwardOption: Equatable, Sendable {
    case authorHidden(Bool), captionsHidden(Bool)
}
public struct TelegramComposerForwardIntent: Codable, Equatable, Sendable {
    public let id: UUID
    public let sources: [TelegramComposerForwardSource]
    public let hideNames: Bool
    public let hideCaptions: Bool
    public let explicitHideNames: Bool?
    public init(id: UUID = UUID(), sources: [TelegramComposerForwardSource], hideNames: Bool = false, hideCaptions: Bool = false,
                explicitHideNames: Bool? = nil) {
        self.id = id; self.sources = sources; self.hideNames = hideNames; self.hideCaptions = hideCaptions
        self.explicitHideNames = explicitHideNames
    }
    public func applying(_ option: TelegramForwardOption) -> Self {
        switch option {
        case let .authorHidden(hidden):
            return .init(id: id, sources: sources, hideNames: hidden, hideCaptions: hideCaptions, explicitHideNames: hidden)
        case let .captionsHidden(hidden):
            return .init(id: id, sources: sources, hideNames: explicitHideNames ?? hidden, hideCaptions: hidden,
                explicitHideNames: explicitHideNames)
        }
    }
    public var isValid: Bool {
        guard !sources.isEmpty, sources.count <= 100, sources.allSatisfy(\.isValid),
              explicitHideNames.map({ $0 == hideNames }) ?? true else { return false }
        let keys = sources.map { "\($0.peerID):\($0.namespace):\($0.messageID)" }
        return Set(keys).count == keys.count
    }
}

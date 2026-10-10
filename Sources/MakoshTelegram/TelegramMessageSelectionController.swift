import Foundation
import Combine
import Postbox

public struct TelegramMessageSelectionID: Hashable, Sendable {
    public let peerID: Int64
    public let namespace: Int32
    public let messageID: Int32
    public init(source: TelegramMessageActionSource) {
        peerID = source.peerID; namespace = source.namespace; messageID = source.messageID
    }
    fileprivate var native: MessageId { MessageId(peerId: PeerId(peerID), namespace: namespace, id: messageID) }
}

public struct TelegramMessageSelectionEntry: Equatable, Sendable {
    public let source: TelegramMessageActionSource
    public var id: TelegramMessageSelectionID { .init(source: source) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.source.fingerprint.utf8.elementsEqual(rhs.source.fingerprint.utf8) &&
            lhs.source.text.utf8.elementsEqual(rhs.source.text.utf8)
    }
}

public struct TelegramMessageSelectionSession: Equatable, Sendable {
    public let id: UUID
    public let contextID: UUID
    public let revision: UUID
    public let accountID: Int64
    public let chatID: Int64
    public let entries: [TelegramMessageSelectionEntry]
    public let invalidIDs: Set<TelegramMessageSelectionID>
    public var sources: [TelegramMessageActionSource] { entries.map(\.source) }
    public var count: Int { entries.count }
    public var canForward: Bool { !entries.isEmpty && invalidIDs.isEmpty && sources.allSatisfy(\.canForward) }
}

/// In-process selection only. Page absence never proves deletion; native forward
/// admission revalidates every frozen source before enqueue.
@MainActor public final class TelegramMessageSelectionController: ObservableObject {
    @Published public private(set) var session: TelegramMessageSelectionSession?
    @Published public private(set) var error: String?
    public init() {}

    @discardableResult
    func begin(source: TelegramMessageActionSource, contextID: UUID) -> Bool {
        guard TelegramComposerForwardSource(source: source).isValid else { return false }
        session = .init(id: UUID(), contextID: contextID, revision: UUID(), accountID: source.accountID, chatID: source.chatID,
                        entries: [.init(source: source)], invalidIDs: [])
        error = nil
        return true
    }

    @discardableResult
    func toggle(source: TelegramMessageActionSource, sessionID: UUID, contextID: UUID) -> Bool {
        guard let current = session, current.id == sessionID, current.contextID == contextID,
              current.accountID == source.accountID, current.chatID == source.chatID else { return false }
        let id = TelegramMessageSelectionID(source: source)
        var entries = current.entries, invalid = current.invalidIDs
        if entries.contains(where: { $0.id == id }) {
            entries.removeAll { $0.id == id }; invalid.remove(id)
        } else {
            guard TelegramComposerForwardSource(source: source).isValid else { return false }
            guard entries.count < 100 else { error = "Можно выбрать не более 100 сообщений."; return false }
            entries.append(.init(source: source))
        }
        entries.sort { $0.id.native < $1.id.native }
        session = .init(id: current.id, contextID: current.contextID, revision: UUID(), accountID: current.accountID,
                        chatID: current.chatID, entries: entries, invalidIDs: invalid)
        error = nil
        return true
    }

    func observe(sources: [TelegramMessageActionSource], contextID: UUID, chatID: Int64) {
        guard let current = session, current.contextID == contextID, current.chatID == chatID else { return }
        var invalid = current.invalidIDs
        for source in sources {
            let id = TelegramMessageSelectionID(source: source)
            guard let frozen = current.entries.first(where: { $0.id == id }) else { continue }
            if source.accountID != current.accountID || source.chatID != current.chatID ||
                !source.fingerprint.utf8.elementsEqual(frozen.source.fingerprint.utf8) ||
                source.threadID != frozen.source.threadID || !source.canForward {
                invalid.insert(id)
            }
        }
        guard invalid != current.invalidIDs else { return }
        session = .init(id: current.id, contextID: current.contextID, revision: UUID(), accountID: current.accountID,
                        chatID: current.chatID, entries: current.entries, invalidIDs: invalid)
    }

    public func contains(_ source: TelegramMessageActionSource) -> Bool {
        guard let session, session.accountID == source.accountID, session.chatID == source.chatID else { return false }
        return session.entries.contains { $0.id == TelegramMessageSelectionID(source: source) }
    }
    func cancel() { session = nil; error = nil }
}

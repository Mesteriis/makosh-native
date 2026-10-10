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
    public let lastSelectedID: TelegramMessageSelectionID?
    public var sources: [TelegramMessageActionSource] { entries.map(\.source) }
    public var count: Int { entries.count }
    public var canForward: Bool { !entries.isEmpty && invalidIDs.isEmpty && sources.allSatisfy { $0.canForward && TelegramComposerForwardSource(source: $0).isValid } }
}

struct TelegramMessageSelectionRangeRequest: Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let revision: UUID
    let contextID: UUID
    let accountID: Int64
    let chatID: Int64
    let anchorID: TelegramMessageSelectionID
    let endpointID: TelegramMessageSelectionID
    var lowerBound: Int32 { min(anchorID.messageID, endpointID.messageID) }
    var upperBoundExclusive: Int32 { max(anchorID.messageID, endpointID.messageID) }
}

/// Page absence never proves deletion. Ranges add cached items only.
@MainActor public final class TelegramMessageSelectionController: ObservableObject {
    @Published public private(set) var session: TelegramMessageSelectionSession?
    @Published public private(set) var error: String?
    @Published public private(set) var isResolvingRange = false
    private(set) var rangeRequest: TelegramMessageSelectionRangeRequest?
    public init() {}

    @discardableResult
    func begin(source: TelegramMessageActionSource, contextID: UUID, extendingRange: Bool = false) -> Bool {
        guard TelegramComposerForwardSource(source: source).isValid else { return false }
        cancelRange()
        session = .init(id: UUID(), contextID: contextID, revision: UUID(), accountID: source.accountID, chatID: source.chatID,
                        entries: [.init(source: source)], invalidIDs: [], lastSelectedID: extendingRange ? nil : .init(source: source))
        error = nil
        return true
    }

    @discardableResult
    func toggle(source: TelegramMessageActionSource, sessionID: UUID, contextID: UUID, extendingRange: Bool = false) -> Bool {
        guard let current = session, current.id == sessionID, current.contextID == contextID,
              current.accountID == source.accountID, current.chatID == source.chatID else { return false }
        cancelRange()
        let id = TelegramMessageSelectionID(source: source)
        var entries = current.entries, invalid = current.invalidIDs, anchor = current.lastSelectedID
        let removing = entries.contains { $0.id == id }
        if removing {
            entries.removeAll { $0.id == id }; invalid.remove(id)
            if !extendingRange {
                // Deterministic adaptation of the reference's arbitrary greater selected item.
                anchor = entries.map(\.id).filter { id.native < $0.native }.min { $0.native < $1.native } ?? id
            }
        } else {
            guard TelegramComposerForwardSource(source: source).isValid else { return false }
            guard entries.count < 100 else { error = "Можно выбрать не более 100 сообщений."; return false }
            entries.append(.init(source: source))
            if !extendingRange { anchor = id }
        }
        entries.sort { $0.id.native < $1.id.native }
        let next = TelegramMessageSelectionSession(id: current.id, contextID: current.contextID, revision: UUID(),
            accountID: current.accountID, chatID: current.chatID, entries: entries, invalidIDs: invalid, lastSelectedID: anchor)
        session = next; error = nil
        if extendingRange, !removing, entries.count < 100, let anchor,
           anchor.peerID == id.peerID, anchor.messageID != id.messageID {
            rangeRequest = .init(id: UUID(), sessionID: next.id, revision: next.revision, contextID: next.contextID,
                accountID: next.accountID, chatID: next.chatID, anchorID: anchor, endpointID: id)
            isResolvingRange = true
        }
        return true
    }

    private func matches(_ request: TelegramMessageSelectionRangeRequest) -> Bool {
        guard rangeRequest == request, let session else { return false }
        return session.id == request.sessionID && session.revision == request.revision &&
            session.contextID == request.contextID && session.accountID == request.accountID && session.chatID == request.chatID
    }

    @discardableResult
    func applyRange(sources: [TelegramMessageActionSource], request: TelegramMessageSelectionRangeRequest) -> Bool {
        guard matches(request), let current = session else { return false }
        guard sources.count <= 200, sources.allSatisfy({ source in
            source.accountID == request.accountID && source.chatID == request.chatID &&
            source.peerID == request.anchorID.peerID && [Int32(0), Int32(1)].contains(source.namespace) &&
            source.messageID > 0 && source.messageID >= request.lowerBound && source.messageID < request.upperBoundExclusive &&
            !source.fingerprint.isEmpty
        }) else { failRange(request: request); return false }
        cancelRange()
        var entries = current.entries, ids = Set(entries.map(\.id)), invalid = current.invalidIDs, overflow = false
        // Cached range reads can reveal a newer version of an off-page selection.
        // Preserve its frozen source, but refuse forwarding the stale snapshot.
        for source in sources {
            let id = TelegramMessageSelectionID(source: source)
            if let frozen = current.entries.first(where: { $0.id == id }),
               !source.fingerprint.utf8.elementsEqual(frozen.source.fingerprint.utf8) ||
                source.threadID != frozen.source.threadID || !source.canForward {
                invalid.insert(id)
            }
        }
        let ordered = sources.sorted {
            if $0.messageID != $1.messageID { return $0.messageID > $1.messageID }
            return $0.namespace < $1.namespace
        }
        for source in ordered {
            let id = TelegramMessageSelectionID(source: source)
            guard !ids.contains(id) else { continue }
            guard entries.count < 100 else { overflow = true; break }
            entries.append(.init(source: source)); ids.insert(id)
        }
        if entries.count != current.entries.count || invalid != current.invalidIDs {
            entries.sort { $0.id.native < $1.id.native }
            session = .init(id: current.id, contextID: current.contextID, revision: UUID(), accountID: current.accountID,
                chatID: current.chatID, entries: entries, invalidIDs: invalid, lastSelectedID: current.lastSelectedID)
        }
        error = overflow ? "Можно выбрать не более 100 сообщений." : nil
        return true
    }

    func cancelRange() { rangeRequest = nil; isResolvingRange = false }
    func failRange(request: TelegramMessageSelectionRangeRequest) {
        guard matches(request) else { return }
        cancelRange(); error = "Не удалось выбрать диапазон сообщений. Выбранные сообщения сохранены."
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
        cancelRange()
        session = .init(id: current.id, contextID: current.contextID, revision: UUID(), accountID: current.accountID,
                        chatID: current.chatID, entries: current.entries, invalidIDs: invalid, lastSelectedID: current.lastSelectedID)
    }

    public func contains(_ source: TelegramMessageActionSource) -> Bool {
        guard let session, session.accountID == source.accountID, session.chatID == source.chatID else { return false }
        return session.entries.contains { $0.id == TelegramMessageSelectionID(source: source) }
    }
    func cancel() { cancelRange(); session = nil; error = nil }
}

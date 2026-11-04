import Foundation

/// AI index source over the shared message archive (Telegram, WhatsApp,
/// Teams). Mail events are skipped: mail has its own source with received
/// letters. The archive is opened read-only.
public final class MessageArchiveIndexSource: AIIndexSource, @unchecked Sendable {
    public let name = "archive"
    private let store: MessageArchiveStore

    public init(connectionString: String, schema: String, keyProvider: @escaping (UUID, Bool) throws -> Data) throws {
        store = try MessageArchiveStore(connectionString: connectionString, schema: schema, readOnly: true, keyProvider: keyProvider)
    }

    public func items(after sequence: Int64, limit: Int) async throws -> [AIIndexItem] {
        try store.records(after: sequence, limit: limit).compactMap(Self.item)
    }

    /// The current state of the conversation: the latest version of each
    /// message, deleted messages left out, ordered by that version's sequence.
    public func items(in scope: AIAccessScope, after sequence: Int64, limit: Int) async throws -> [AIIndexItem] {
        guard case .conversation(let service, let accountID, let conversationID) = scope, service != "mail", (1...200).contains(limit)
        else {
            return []
        }
        var latest: [MessageArchiveIdentity: AIIndexItem] = [:]
        var cursor: Int64 = 0
        for _ in 0..<Self.maximumPages {
            let page = try store.records(service: service, accountID: accountID, conversationID: conversationID, after: cursor, limit: 200)
            for item in page.compactMap(Self.item) { latest[item.identity] = item }
            guard page.count == 200, let last = page.last?.sequence else { break }
            cursor = last
        }
        return Array(latest.values.filter { !$0.removed && $0.sequence > sequence }.sorted { $0.sequence < $1.sequence }.prefix(limit))
    }
    /// Bounds one back-fill scan to 200 000 archive versions.
    private static let maximumPages = 1000

    private static func item(_ record: MessageArchiveRecord) -> AIIndexItem? {
        let observation = record.observation, identity = observation.identity
        guard identity.service != "mail" else { return nil }
        let scope = AIAccessScope.conversation(
            service: identity.service, accountID: identity.accountID, conversationID: identity.conversationID)
        switch observation.event {
        case .message(let content):
            let author = content.authorID.flatMap {
                $0.isEmpty ? nil : ServiceIdentity(service: identity.service, accountID: identity.accountID, externalID: $0)
            }
            return AIIndexItem(
                sequence: record.sequence, identity: identity, scope: scope, author: author, isOutgoing: content.isOutgoing,
                date: content.date,
                title: "", text: content.text, removed: false)
        case .deleted, .removedFromSource:
            return AIIndexItem(
                sequence: record.sequence, identity: identity, scope: scope, author: nil, isOutgoing: false, date: observation.observedAt,
                title: "", text: "", removed: true)
        }
    }
}

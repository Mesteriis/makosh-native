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

    public func items(in scope: AIAccessScope, after sequence: Int64, limit: Int) async throws -> [AIIndexItem] {
        guard case .conversation(let service, let accountID, let conversationID) = scope, service != "mail" else { return [] }
        return try store.records(service: service, accountID: accountID, conversationID: conversationID, after: sequence, limit: limit)
            .compactMap(Self.item)
    }

    private static func item(_ record: MessageArchiveRecord) -> AIIndexItem? {
        let observation = record.observation, identity = observation.identity
        guard identity.service != "mail" else { return nil }
        let scope = AIAccessScope.conversation(service: identity.service, accountID: identity.accountID, conversationID: identity.conversationID)
        switch observation.event {
        case .message(let content):
            let author = content.authorID.flatMap { $0.isEmpty ? nil : ServiceIdentity(service: identity.service, accountID: identity.accountID, externalID: $0) }
            return AIIndexItem(
                sequence: record.sequence, identity: identity, scope: scope, author: author, isOutgoing: content.isOutgoing, date: content.date,
                title: "", text: content.text, removed: false)
        case .deleted, .removedFromSource:
            return AIIndexItem(
                sequence: record.sequence, identity: identity, scope: scope, author: nil, isOutgoing: false, date: observation.observedAt,
                title: "", text: "", removed: true)
        }
    }
}

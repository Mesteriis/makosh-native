import Foundation
import MakoshCore

/// An in-memory address book for tests and the isolated QA bundle. It never touches
/// the network. `failNext` applies the write and then throws, as a dropped connection
/// after the server committed would; `applying: false` drops the write entirely.
public actor PersonSyntheticBook: PersonBookAdapter {
    private struct Stored {
        var card: RemoteCard
        var revision: Int
    }
    private var cards: [String: Stored] = [:]
    private var log: [(revision: Int, externalID: String, removed: Bool)] = []
    private var revision = 0
    private var counter = 0
    private var pendingFailure: (failure: PersonsFailure, applying: Bool)?
    private var findFailure: PersonsFailure?
    private let capabilitiesValue: PersonBookCapabilities
    /// Every write in order: "create <externalID>", "update <externalID>", "delete <externalID>".
    public private(set) var writes: [String] = []
    public private(set) var reads = 0

    public init(
        cards: [RemoteCard] = [],
        capabilities: PersonBookCapabilities = .init(acceptsOrganizations: true, requiresPhoneOrPeer: false, supportsMarker: true)
    ) {
        capabilitiesValue = capabilities
        for card in cards {
            revision += 1
            self.cards[card.externalID] = Stored(card: card, revision: revision)
            log.append((revision, card.externalID, false))
        }
    }

    public var capabilities: PersonBookCapabilities { capabilitiesValue }

    public func failNext(_ failure: PersonsFailure, applying: Bool = true) { pendingFailure = (failure, applying) }

    /// While set, looking a card up by the mark fails (a book that cannot be reached for a check); nil clears it.
    public func failFind(_ failure: PersonsFailure?) { findFailure = failure }

    /// A change made outside Makosh: the ETag moves.
    public func editRemotely(externalID: String, _ change: (inout ImportedPerson) -> Void) {
        guard var stored = cards[externalID] else { return }
        change(&stored.card.imported)
        revision += 1
        stored.revision = revision
        stored.card.etag = "\"\(revision)\""
        cards[externalID] = stored
        log.append((revision, externalID, false))
    }

    public func removeRemotely(externalID: String) {
        guard cards.removeValue(forKey: externalID) != nil else { return }
        revision += 1
        log.append((revision, externalID, true))
    }

    /// The current card of a person, as the book holds it.
    public func card(for makoshID: UUID) -> RemoteCard? { cards.values.first { $0.card.makoshID == makoshID }?.card }

    public func changes(cursor: Data?) async throws -> RemoteCardChanges {
        reads += 1
        let since = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        let next = Data(String(revision).utf8)
        guard let since else {
            return RemoteCardChanges(cards: cards.values.sorted { $0.revision < $1.revision }.map(\.card), cursor: next, full: true)
        }
        var changed: [String: Bool] = [:]
        for entry in log where entry.revision > since { changed[entry.externalID] = entry.removed }
        let updated = changed.filter { !$0.value }.keys.compactMap { cards[$0]?.card }
        let removed = changed.filter { $0.value && cards[$0.key] == nil }.keys.sorted()
        return RemoteCardChanges(cards: updated, removedExternalIDs: removed, cursor: next, full: false)
    }

    public func create(_ card: PersonCard) async throws -> RemoteCardRef {
        counter += 1
        let externalID = "syn-\(counter)"
        let apply = {
            self.revision += 1
            let remote = RemoteCard(
                externalID: externalID, etag: "\"\(self.revision)\"", makoshID: card.makoshID,
                imported: Self.imported(card, externalID: externalID),
                kind: card.kind)
            self.cards[externalID] = Stored(card: remote, revision: self.revision)
            self.log.append((self.revision, externalID, false))
            self.writes.append("create " + externalID)
        }
        try fail(then: apply)
        return RemoteCardRef(externalID: externalID, etag: "\"\(revision)\"")
    }

    public func update(externalID: String, etag: String?, card: PersonCard) async throws -> RemoteCardRef {
        guard let stored = cards[externalID] else { throw PersonsFailure.notFound }
        if let etag, etag != stored.card.etag { throw PersonsFailure.preconditionFailed }
        let apply = {
            self.revision += 1
            let remote = RemoteCard(
                externalID: externalID, etag: "\"\(self.revision)\"", makoshID: card.makoshID,
                imported: Self.imported(card, externalID: externalID),
                kind: card.kind)
            self.cards[externalID] = Stored(card: remote, revision: self.revision)
            self.log.append((self.revision, externalID, false))
            self.writes.append("update " + externalID)
        }
        try fail(then: apply)
        return RemoteCardRef(externalID: externalID, etag: "\"\(revision)\"")
    }

    public func delete(externalID: String, etag: String?) async throws {
        guard let stored = cards[externalID] else { throw PersonsFailure.notFound }
        if let etag, etag != stored.card.etag { throw PersonsFailure.preconditionFailed }
        try fail {
            self.cards[externalID] = nil
            self.revision += 1
            self.log.append((self.revision, externalID, true))
            self.writes.append("delete " + externalID)
        }
    }

    public func find(makoshID: UUID) async throws -> RemoteCardRef? {
        if let findFailure { throw findFailure }
        guard let stored = cards.values.first(where: { $0.card.makoshID == makoshID }) else { return nil }
        return RemoteCardRef(externalID: stored.card.externalID, etag: stored.card.etag)
    }

    private func fail(then apply: () -> Void) throws {
        if let pending = pendingFailure {
            pendingFailure = nil
            if pending.applying { apply() }
            throw pending.failure
        }
        apply()
    }

    static func imported(_ card: PersonCard, externalID: String) -> ImportedPerson {
        ImportedPerson(
            externalID: externalID, displayName: card.displayName, givenName: card.givenName.isEmpty ? nil : card.givenName,
            familyName: card.familyName.isEmpty ? nil : card.familyName, middleName: card.middleName.isEmpty ? nil : card.middleName,
            organization: card.organization.isEmpty ? nil : card.organization, jobTitle: card.jobTitle.isEmpty ? nil : card.jobTitle,
            phones: card.phones, emails: card.emails)
    }
}

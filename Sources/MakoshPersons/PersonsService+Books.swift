import Foundation
import MakoshCore

extension PersonsService {
    /// Reads one book: cards become observations, cards Makosh manages report values removed
    /// outside, removed cards drop to «not managed», and a write pass follows.
    @discardableResult
    public func readBook(id: UUID) async throws -> CollectResult {
        guard let book = try await store.book(id: id), book.kind.isBook else { throw PersonsFailure.notFound }
        let adapter: any PersonBookAdapter
        let changes: RemoteCardChanges
        do {
            adapter = try await self.adapter(for: book)
            changes = try await adapter.changes(cursor: book.cursor)
        } catch let failure as PersonsFailure {
            await mark(id, failure: failure)
            throw failure
        }
        let entries = try await store.entries(bookID: id)
        let managed = Dictionary(uniqueKeysWithValues: entries.filter { $0.state == .managed }.map { ($0.externalID, $0) })
        var observations: [PersonSourceObservation] = []
        for card in changes.cards {
            var imported = card.imported
            imported.externalID = card.externalID
            if imported.kind == nil, card.kind == .organization { imported.kind = .organization }
            observations.append(
                PersonSourceObservation(
                    source: book.source, person: imported, observedAt: now(), evidence: .book,
                    personID: managed[card.externalID]?.personID ?? card.makoshID))
            guard var entry = managed[card.externalID] else { continue }
            // Values Makosh sent that the card no longer carries were removed by the user out there.
            for (field, sent) in entry.sentValues {
                guard let listField = PersonListField(rawValue: field) else { continue }
                let current = listField == .phones ? imported.phones : imported.emails
                let normalizedCurrent = Set(current.map { PersonMatching.normalized(listField, $0) })
                for value in sent where !normalizedCurrent.contains(PersonMatching.normalized(listField, value)) {
                    try persons.removeValue(personID: entry.personID, field: listField, value: value, reason: .removedInBook(book.source))
                }
                entry.sentValues[field] = current
            }
            if entry.etag != card.etag {
                entry.etag = card.etag
                entry.updatedAt = now()
            }
            try await store.saveEntry(entry)
        }
        for externalID in changes.removedExternalIDs {
            guard var entry = managed[externalID] else { continue }
            entry.state = .notManaged
            entry.updatedAt = now()
            try await store.saveEntry(entry)
        }
        if changes.full {
            lastRemote[id] = changes.cards
            // A full read is authoritative: a managed card missing from it is gone.
            let present = Set(changes.cards.map(\.externalID))
            for (externalID, var entry) in managed where !present.contains(externalID) && !changes.removedExternalIDs.contains(externalID) {
                entry.state = .notManaged
                entry.updatedAt = now()
                try await store.saveEntry(entry)
            }
        } else {
            var cache = (lastRemote[id] ?? []).filter { card in
                !changes.removedExternalIDs.contains(card.externalID) && !changes.cards.contains { $0.externalID == card.externalID }
            }
            cache.append(contentsOf: changes.cards)
            lastRemote[id] = cache
        }
        let result = try await collect(observations, addressBookSource: book.isAddressBookSource ? book.source : nil)
        if var current = try await store.book(id: id) {
            current.cursor = changes.cursor
            current.pausedUntil = nil
            if current.state == .unreachable {
                current.state = .connected
                current.lastError = nil
            }
            try await store.saveBook(current)
        }
        pendingRead.remove(id)
        requestWritePass()
        return result
    }
}

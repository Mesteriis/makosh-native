import Foundation
import MakoshCore

extension PersonsService {
    /// One pass over every writable book: journal, send, settle. Never more than
    /// `limitPerBook` attempts per book; an open attempt for a person in a book blocks a new one.
    public func writePass(limitPerBook: Int? = nil) async -> PersonsPassReport {
        var report = PersonsPassReport()
        guard let books = try? await writableBooks(), let preferences = try? await store.preferences() else { return report }
        let limit = limitPerBook ?? preferences.maxWritesPerPass
        var capabilityMap: [UUID: PersonBookCapabilities] = [:]
        var usable: [PersonBook] = []
        for book in books {
            if let capability = await capabilities(for: book) {
                capabilityMap[book.id] = capability
                usable.append(book)
            } else {
                await mark(book.id, failure: .signInRequired)
            }
        }
        // Unknown attempts are settled by reading before anything else is written.
        if let open = try? await store.attempts(open: true) {
            for book in usable where open.contains(where: { $0.bookID == book.id && $0.state == .unknown }) {
                try? await settleUnknown(bookID: book.id)
            }
        }
        guard let active = try? persons.persons(), let memberships = try? persons.allMemberships(includingRemoved: false),
            let entries = try? await store.allEntries(), let openAttempts = try? await store.attempts(open: true)
        else { return report }
        let identities = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0.identities) })
        let desired = AddressBookEngine.desired(
            persons: active, memberships: memberships, books: usable, capabilities: capabilityMap, sourceIdentities: identities)
        // A book this process has not read in full is read before a card may be created or adopted in it:
        // the person's own source card or a marked card must be found, not duplicated.
        for book in usable where !authoritativeRemote.contains(book.id) {
            let needsLook = desired.contains { wanted in
                wanted.bookID == book.id
                    && !entries.contains { $0.personID == wanted.personID && $0.bookID == book.id && $0.state == .managed }
            }
            guard needsLook, let adapter = try? await adapter(for: book), let changes = try? await adapter.changes(cursor: nil),
                changes.full
            else { continue }
            lastRemote[book.id] = changes.cards
            authoritativeRemote.insert(book.id)
        }
        let writes = AddressBookEngine.reconcile(desired: desired, entries: entries, remote: lastRemote, sourceIdentities: identities)
        let blocked = Set(openAttempts.map { $0.personID.uuidString + "|" + $0.bookID.uuidString })
        var perBook: [UUID: [PersonWrite]] = [:]
        for write in writes {
            guard let wanted = write.desired, !blocked.contains(wanted.personID.uuidString + "|" + wanted.bookID.uuidString) else {
                continue
            }
            if await isRepeatOfRejected(wanted, entries: entries) { continue }
            perBook[wanted.bookID, default: []].append(write)
        }
        for book in usable {
            let pending = perBook[book.id] ?? []
            if pending.count > limit { report.deferredBooks.append(book.id) }
            for write in pending.prefix(limit) {
                guard let wanted = write.desired else { continue }
                report.attempted += 1
                switch await perform(write, in: book) {
                case .confirmed: report.confirmed += 1
                case .rejected: report.rejected += 1
                default: report.unknown += 1
                }
                // A book that lost its session or access stops here; the others go on.
                if let state = try? await store.book(id: book.id)?.state, state != .connected {
                    _ = wanted
                    break
                }
            }
        }
        return report
    }

    /// A card the book refused stays unsent until it changes, the user asks again, or the book is reread.
    func isRepeatOfRejected(_ wanted: DesiredCard, entries: [PersonBookEntry]) async -> Bool {
        guard let attempts = try? await store.attempts(personID: wanted.personID),
            let last = attempts.filter({ $0.bookID == wanted.bookID }).max(by: { $0.updatedAt < $1.updatedAt }),
            last.state == .rejected, last.fingerprint == wanted.card.fingerprint, let failure = last.failure,
            Self.isPermanentRejection(failure)
        else { return false }
        let touched = entries.filter { $0.personID == wanted.personID && $0.bookID == wanted.bookID }.map(\.updatedAt).max()
        return touched.map { $0 <= last.updatedAt } ?? true
    }

    /// The book refused this card itself; a lost session, a missing card or a transport doubt are not refusals.
    static func isPermanentRejection(_ failure: PersonsFailure) -> Bool {
        switch failure {
        case .notInTelegram, .noPhoneOrPeer, .invalidInput: true
        case .rejected(let code, _): (400...499).contains(code) && code != 401 && code != 403 && code != 404 && code != 412
        default: false
        }
    }

    /// Journals and sends one write; the attempt's final state is the result.
    func perform(_ write: PersonWrite, in book: PersonBook) async -> PersonAttemptState {
        guard let wanted = write.desired else { return .rejected }
        let kind: PersonAttemptKind
        let entry: PersonBookEntry?
        switch write {
        case .create:
            kind = .create
            entry = nil
        case .adopt:
            kind = .update
            entry = nil
        case .update(_, let existing):
            kind = .update
            entry = existing
        case .none: return .rejected
        }
        var attempt = PersonAttempt(
            personID: wanted.personID, bookID: book.id, entryID: entry?.id, kind: kind, fingerprint: wanted.card.fingerprint)
        do {
            try await store.saveAttempt(attempt)
            attempt.state = .sent
            try await store.saveAttempt(attempt)
        } catch { return .rejected }
        let ref: RemoteCardRef
        do {
            let adapter = try await adapter(for: book)
            switch write {
            case .create: ref = try await adapter.create(wanted.card, hint: wanted.bookExternalID)
            case .adopt(_, let externalID, let etag): ref = try await adapter.update(externalID: externalID, etag: etag, card: wanted.card)
            case .update(_, let existing):
                ref = try await adapter.update(externalID: existing.externalID, etag: existing.etag, card: wanted.card)
            case .none: return .rejected
            }
        } catch {
            return await settle(attempt, error: error, entry: entry, book: book)
        }
        // The book answered: a local failure from here on is no refusal. The attempt stays unknown
        // and the next pass finds the card by its mark instead of sending it again.
        do {
            var saved =
                entry
                ?? PersonBookEntry(
                    personID: wanted.personID, bookID: book.id, externalID: ref.externalID, etag: ref.etag,
                    fingerprint: wanted.card.fingerprint, state: .managed)
            saved.externalID = ref.externalID
            saved.etag = ref.etag
            saved.fingerprint = wanted.card.fingerprint
            saved.sentValues = ["phones": wanted.card.phones, "emails": wanted.card.emails]
            saved.state = .managed
            saved.updatedAt = now()
            try await store.saveEntry(saved)
            attempt.entryID = saved.id
            attempt.state = .confirmed
            try? await store.saveAttempt(attempt)
            return .confirmed
        } catch {
            attempt.state = .unknown
            attempt.failure = (error as? PersonsFailure) ?? .unknownOutcome(stage: "entry")
            try? await store.saveAttempt(attempt)
            return .unknown
        }
    }

    /// Transport doubt stays unknown; everything else is rejected, and the book learns of lost access.
    func settle(_ attempt: PersonAttempt, error: Error, entry: PersonBookEntry?, book: PersonBook) async -> PersonAttemptState {
        var attempt = attempt
        let failure = (error as? PersonsFailure) ?? .unknownOutcome(stage: "write")
        switch failure {
        case .unknownOutcome:
            attempt.state = .unknown
        case .preconditionFailed:
            attempt.state = .rejected
            pendingRead.insert(book.id)
        case .notFound:
            attempt.state = .rejected
            if var gone = entry {
                gone.state = .notManaged
                gone.updatedAt = now()
                try? await store.saveEntry(gone)
            }
        case .signInRequired, .noAccess, .unreachable, .retryAfter, .rejected(code: 401, _), .rejected(code: 403, _):
            attempt.state = .rejected
            await mark(book.id, failure: failure)
        default:
            attempt.state = .rejected
        }
        attempt.failure = failure
        try? await store.saveAttempt(attempt)
        return attempt.state
    }

    /// Settles the book's unknown attempts by looking for the mark, never by sending again.
    public func settleUnknown(bookID: UUID) async throws {
        guard let book = try await store.book(id: bookID) else { throw PersonsFailure.notFound }
        let unknown = try await store.attempts(open: true).filter { $0.bookID == bookID && $0.state == .unknown }
        guard !unknown.isEmpty else { return }
        let adapter = try await adapter(for: book)
        let capability = await adapter.capabilities
        // A book without a mark (Telegram) answers by its whole list: the peer or the phone is there or not.
        var remoteCards: [RemoteCard]?
        if !capability.supportsMarker, let changes = try? await adapter.changes(cursor: nil), changes.full {
            remoteCards = changes.cards
            lastRemote[bookID] = changes.cards
            authoritativeRemote.insert(bookID)
        }
        for var attempt in unknown {
            let found: RemoteCardRef?
            if capability.supportsMarker {
                found = try await adapter.find(makoshID: attempt.personID)
            } else if let remoteCards {
                var entry: PersonBookEntry?
                if let entryID = attempt.entryID { entry = try await store.entry(id: entryID) }
                found = Self.presence(
                    of: attempt, in: remoteCards, person: try persons.person(id: attempt.personID), book: book, entry: entry)
            } else {
                continue
            }
            switch (attempt.kind, found) {
            case (.delete, nil):
                attempt.state = .confirmed
                if let id = attempt.entryID, var entry = try await store.entry(id: id) {
                    entry.state = .removed
                    entry.updatedAt = now()
                    try await store.saveEntry(entry)
                }
            case (.delete, .some):
                attempt.state = .rejected
                attempt.failure = .rejected(code: 0, stage: "delete not applied")
            case (_, .some(let ref)):
                attempt.state = .confirmed
                var existing: PersonBookEntry?
                if let id = attempt.entryID { existing = try await store.entry(id: id) }
                if existing == nil { existing = try await store.entry(bookID: bookID, externalID: ref.externalID) }
                var entry =
                    existing
                    ?? PersonBookEntry(
                        personID: attempt.personID, bookID: bookID, externalID: ref.externalID, etag: ref.etag,
                        fingerprint: attempt.fingerprint,
                        state: .managed)
                entry.externalID = ref.externalID
                entry.etag = ref.etag
                entry.fingerprint = attempt.fingerprint
                entry.state = .managed
                entry.personID = attempt.personID
                entry.updatedAt = now()
                try await store.saveEntry(entry)
                attempt.entryID = entry.id
            case (_, nil):
                // The whole book was looked at and the card is not there: the write never applied.
                attempt.state = .rejected
                attempt.failure = .notFound
            }
            try await store.saveAttempt(attempt)
        }
    }

    /// Where a book carries no mark: the entry's card, the person's peer in this book, or a card with one of the person's phones.
    static func presence(
        of attempt: PersonAttempt, in cards: [RemoteCard], person: Person?, book: PersonBook, entry: PersonBookEntry?
    ) -> RemoteCardRef? {
        if let entry, let card = cards.first(where: { $0.externalID == entry.externalID }) {
            return RemoteCardRef(externalID: card.externalID, etag: card.etag)
        }
        guard let person else { return nil }
        if let peer = person.identities.first(where: { $0.service == book.kind.service && $0.accountID == book.accountID }),
            let card = cards.first(where: { $0.externalID == peer.externalID })
        {
            return RemoteCardRef(externalID: card.externalID, etag: card.etag)
        }
        let phones = Set(person.phones.map { PersonMatching.normalized(.phones, $0) })
        guard !phones.isEmpty,
            let card = cards.first(where: { card in
                card.imported.phones.contains { phones.contains(PersonMatching.normalized(.phones, $0)) }
            })
        else { return nil }
        return RemoteCardRef(externalID: card.externalID, etag: card.etag)
    }

    /// «Отказаться»: the user closes an unknown attempt without checking.
    public func dismissAttempt(id: UUID) async throws {
        guard var attempt = try await store.attempt(id: id), attempt.state == .unknown else { throw PersonsFailure.notFound }
        attempt.state = .rejected
        attempt.failure = .rejected(code: 0, stage: "dismissed")
        try await store.saveAttempt(attempt)
    }

    /// «Удалить везде»: one delete attempt per managed or duplicate card of the person.
    @discardableResult
    public func deleteEverywhere(personID: UUID) async throws -> [PersonAttempt] {
        var attempts: [PersonAttempt] = []
        for entry in try await store.entries(personID: personID) where entry.state == .managed || entry.state == .duplicate {
            guard let book = try await store.book(id: entry.bookID), book.state == .connected else { continue }
            attempts.append(await deleteCard(entry, in: book))
        }
        return attempts
    }

    /// Deletes the second card a merge left in a book.
    public func deleteDuplicateEntry(id: UUID) async throws {
        guard let entry = try await store.entry(id: id), entry.state == .duplicate, let book = try await store.book(id: entry.bookID) else {
            throw PersonsFailure.notFound
        }
        _ = await deleteCard(entry, in: book)
    }

    func deleteCard(_ entry: PersonBookEntry, in book: PersonBook) async -> PersonAttempt {
        var attempt = PersonAttempt(
            personID: entry.personID, bookID: book.id, entryID: entry.id, kind: .delete, fingerprint: entry.fingerprint)
        do {
            try await store.saveAttempt(attempt)
            attempt.state = .sent
            try await store.saveAttempt(attempt)
            let adapter = try await adapter(for: book)
            do { try await adapter.delete(externalID: entry.externalID, etag: entry.etag) } catch PersonsFailure.notFound {}
        } catch {
            _ = await settle(attempt, error: error, entry: nil, book: book)
            return (try? await store.attempt(id: attempt.id)) ?? attempt
        }
        // The book answered: a local failure here leaves the attempt unknown, settled by the next read.
        do {
            var removed = entry
            removed.state = .removed
            removed.updatedAt = now()
            try await store.saveEntry(removed)
            attempt.state = .confirmed
            try await store.saveAttempt(attempt)
        } catch {
            attempt.state = .unknown
            attempt.failure = (error as? PersonsFailure) ?? .unknownOutcome(stage: "entry")
            try? await store.saveAttempt(attempt)
        }
        return attempt
    }

    /// A card the user removed outside Makosh comes back on request.
    public func resend(entryID: UUID) async throws {
        guard var entry = try await store.entry(id: entryID), entry.state == .notManaged else { throw PersonsFailure.notFound }
        entry.state = .removed
        entry.updatedAt = now()
        try await store.saveEntry(entry)
        requestWritePass()
    }

    // MARK: Merges

    /// Joins two persons and lets their cards follow: one managed card per book survives,
    /// the other becomes a duplicate the user may delete.
    public func mergePersons(survivorID: UUID, removedID: UUID) async throws {
        _ = try persons.merge(survivorID: survivorID, removedID: removedID)
        try await moveEntries(from: removedID, to: survivorID)
    }

    func moveEntries(from removedID: UUID, to survivorID: UUID) async throws {
        let survivorEntries = try await store.entries(personID: survivorID)
        for var entry in try await store.entries(personID: removedID) {
            entry.mergedFromPersonID = removedID
            entry.personID = survivorID
            if entry.state == .managed, survivorEntries.contains(where: { $0.bookID == entry.bookID && $0.state == .managed }) {
                entry.state = .duplicate
            }
            entry.updatedAt = now()
            try await store.saveEntry(entry)
        }
    }

    public func undoMerge(id: UUID) async throws {
        guard let record = try persons.mergeHistory().first(where: { $0.id == id }) else { throw PersonsFailure.notFound }
        try persons.undoMerge(id: id)
        for var entry in try await store.entries(personID: record.survivorBefore.id)
        where entry.mergedFromPersonID == record.removedBefore.id {
            entry.personID = record.removedBefore.id
            entry.mergedFromPersonID = nil
            if entry.state == .duplicate { entry.state = .managed }
            entry.updatedAt = now()
            try await store.saveEntry(entry)
        }
    }
}

extension PersonWrite {
    var desired: DesiredCard? {
        switch self {
        case .create(let card), .adopt(let card, _, _), .update(let card, _): card
        case .none: nil
        }
    }
}

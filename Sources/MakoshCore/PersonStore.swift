import Foundation

/// Local PostgreSQL contact book. Every mutation runs in one transaction under a
/// schema-scoped writer lock and rereads the rows it changes, so independent app
/// connections cannot overwrite each other's state. Persistence is in
/// `PersonRecordRepository`; provenance rules are in `PersonReconciliation`.
public final class PersonStore {
    private typealias Rules = PersonReconciliation
    private let lock = NSLock()
    private let repository: PersonRecordRepository

    public init(connectionString: String, schema: String = "makosh") throws {
        repository = try PersonRecordRepository(connectionString: connectionString, schema: schema)
    }

    public func persons() throws -> [Person] {
        try read { try $0.allPersons() }.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    public func person(id: UUID) throws -> Person? {
        try read { try $0.person(id: id) }
    }

    public func createPerson(draft: PersonDraft) throws -> UUID {
        try Rules.validate(draft)
        return try write { repository in
            var contact = Person(displayName: Rules.trimmed(draft.displayName))
            Rules.apply(draft, to: &contact)
            contact.manualFields = ["displayName", "organization", "jobTitle", "phones", "emails", "tags"]
            Rules.recordManualChanges(from: nil, contact: &contact)
            contact.events.append(PersonEvent(kind: "created", detail: "Контакт создан вручную"))
            try repository.insert(contact)
            return contact.id
        }
    }

    public func updatePerson(id: UUID, draft: PersonDraft) throws {
        try Rules.validate(draft)
        try write { repository in
            guard var contact = try repository.person(id: id) else { throw StoreError.missingPerson }
            let before = contact.draft
            Rules.apply(draft, to: &contact)
            let after = contact.draft
            guard before != after else { return }
            if before.displayName != after.displayName { contact.manualFields.insert("displayName") }
            if before.organization != after.organization { contact.manualFields.insert("organization") }
            if before.jobTitle != after.jobTitle { contact.manualFields.insert("jobTitle") }
            if before.phones != after.phones { contact.manualFields.insert("phones") }
            if before.emails != after.emails { contact.manualFields.insert("emails") }
            if before.tags != after.tags { contact.manualFields.insert("tags") }
            Rules.recordManualChanges(from: before, contact: &contact)
            contact.revision += 1
            contact.events.append(PersonEvent(kind: "edited", detail: "Изменено вручную"))
            try repository.update(contact)
        }
    }

    public func addSourceNote(contactID: UUID, note: PersonNote) throws -> UUID {
        let source = note.source.identity
        guard !Rules.trimmed(note.text).isEmpty, note.text.utf8.count <= 64 * 1024,
            [source.service, source.accountID, source.externalID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }),
            note.source.fetchedAt.timeIntervalSince1970.isFinite
        else { throw StoreError.invalid("Некорректная заметка источника.") }
        return try write { repository in
            let owners = try repository.persons(owningNote: note.id)
            if let owner = owners.first {
                guard owners.count == 1, let existing = owner.notes.first(where: { $0.id == note.id }),
                    existing.text.utf8.elementsEqual(note.text.utf8), existing.source == note.source
                else {
                    throw StoreError.invalid("Идентификатор заметки уже связан с другим содержимым.")
                }
                return owner.id
            }
            guard var contact = try repository.person(id: contactID) else { throw StoreError.missingPerson }
            contact.notes.append(note)
            contact.revision += 1
            contact.events.append(.init(kind: "sourceNote", detail: "Добавлена заметка с источником"))
            try repository.update(contact)
            return contactID
        }
    }

    public func addNote(contactID: UUID, text: String) throws {
        guard !Rules.trimmed(text).isEmpty else { throw StoreError.invalid("Заметка не может быть пустой.") }
        try write { repository in
            guard var contact = try repository.person(id: contactID) else { throw StoreError.missingPerson }
            let identity = ServiceIdentity(service: "manual", accountID: "local", externalID: contactID.uuidString)
            contact.notes.append(PersonNote(text: Rules.trimmed(text), source: SourceStamp(identity: identity)))
            contact.revision += 1
            contact.events.append(PersonEvent(kind: "note", detail: "Добавлена заметка"))
            try repository.update(contact)
        }
    }

    public func setAIAccess(contactID: UUID, access: AIContactAccess) throws {
        try write { repository in
            guard var contact = try repository.person(id: contactID) else { throw StoreError.missingPerson }
            guard contact.aiAccess != access else { return }
            contact.aiAccess = access
            contact.revision += 1
            contact.events.append(PersonEvent(kind: "aiAccess", detail: "Доступ для ИИ изменён"))
            try repository.update(contact)
        }
    }

    public func importJSON(data: Data) throws -> ImportResult {
        try importDocument(ImportDocument.decode(data))
    }

    public func importDocument(_ document: ImportDocument) throws -> ImportResult {
        guard document.schemaVersion == 1 else { throw StoreError.unsupportedSchema(document.schemaVersion) }
        guard !Rules.trimmed(document.source.service).isEmpty, !Rules.trimmed(document.source.accountID).isEmpty,
            document.fetchedAt.timeIntervalSince1970.isFinite
        else { throw StoreError.invalid("Укажите источник, аккаунт и дату импорта.") }
        var keys = Set<String>()
        for incoming in document.contacts {
            guard !Rules.trimmed(incoming.externalID).isEmpty else { throw StoreError.invalid("Отсутствует внешний идентификатор.") }
            try Rules.validate(PersonDraft(displayName: incoming.displayName))
            let identity = ServiceIdentity(
                service: document.source.service, accountID: document.source.accountID, externalID: incoming.externalID)
            guard keys.insert(identity.id).inserted else { throw StoreError.invalid("Повтор внешнего идентификатора в одном импорте.") }
        }
        return try write { repository in
            var result = ImportResult(created: 0, updated: 0)
            for incoming in document.contacts {
                let identity = ServiceIdentity(
                    service: document.source.service, accountID: document.source.accountID, externalID: incoming.externalID)
                let previous = try repository.fetchedAt(identity)
                if let previous, document.fetchedAt < previous { continue }
                let stamp = SourceStamp(identity: identity, fetchedAt: document.fetchedAt)
                let existing = try repository.persons(owning: identity).first
                var contact = existing ?? Person(displayName: Rules.trimmed(incoming.displayName), identities: [identity])
                Rules.absorb(incoming, source: stamp, into: &contact)
                try repository.setFetchedAt(max(previous ?? document.fetchedAt, document.fetchedAt), for: identity)
                if let before = existing {
                    guard contact != before else { continue }
                    contact.revision += 1
                    if Rules.contentWithoutFetchDates(contact) != Rules.contentWithoutFetchDates(before) {
                        contact.events.append(
                            PersonEvent(date: document.fetchedAt, kind: "import", detail: "Обновлено из \(identity.service)"))
                    }
                    try repository.update(contact)
                    result.updated += 1
                } else {
                    contact.events.append(
                        PersonEvent(date: document.fetchedAt, kind: "import", detail: "Импортировано из \(identity.service)"))
                    try repository.insert(contact)
                    result.created += 1
                }
            }
            return result
        }
    }

    /// Explicitly attaches a source identity without moving it between contacts.
    @discardableResult
    public func linkImportedPerson(
        _ incoming: ImportedPerson, source: ImportSource,
        fetchedAt: Date, contactID: UUID?
    ) throws -> UUID {
        guard !Rules.trimmed(source.service).isEmpty, !Rules.trimmed(source.accountID).isEmpty,
            !Rules.trimmed(incoming.externalID).isEmpty, fetchedAt.timeIntervalSince1970.isFinite
        else {
            throw StoreError.invalid("Некорректные данные привязки контакта.")
        }
        try Rules.validate(PersonDraft(displayName: incoming.displayName))
        let identity = ServiceIdentity(service: source.service, accountID: source.accountID, externalID: incoming.externalID)
        return try write { repository in
            let owners = try repository.persons(owning: identity)
            guard owners.count <= 1, owners.allSatisfy({ $0.identities.filter { $0 == identity }.count == 1 }) else {
                throw StoreError.invalid("Неоднозначная привязка источника контакта.")
            }
            let existing: Person?
            if let contactID {
                guard let target = try repository.person(id: contactID), owners.first.map({ $0.id == target.id }) ?? true else {
                    throw StoreError.invalid("Не удалось привязать источник к выбранному контакту.")
                }
                existing = target
            } else {
                existing = owners.first
            }
            var contact = existing ?? Person(displayName: Rules.trimmed(incoming.displayName))
            let before = contact
            let attached = !contact.identities.contains(identity)
            if attached { contact.identities.append(identity) }
            let previousFetched = try repository.fetchedAt(identity)
            var currentFetched = previousFetched
            if !(previousFetched.map { fetchedAt < $0 } ?? false) {
                Rules.absorb(incoming, source: SourceStamp(identity: identity, fetchedAt: fetchedAt), into: &contact)
                currentFetched = max(previousFetched ?? fetchedAt, fetchedAt)
                try repository.setFetchedAt(currentFetched ?? fetchedAt, for: identity)
            }
            let sourceChanged = currentFetched != previousFetched
            if attached {
                contact.events.append(PersonEvent(date: fetchedAt, kind: "identityLink", detail: "Привязан источник контакта"))
            } else if Rules.contentWithoutFetchDates(contact) != Rules.contentWithoutFetchDates(before) {
                contact.events.append(PersonEvent(date: fetchedAt, kind: "import", detail: "Обновлено из источника контакта"))
            }
            if existing != nil {
                if contact != before || sourceChanged {
                    contact.revision += 1
                    try repository.update(contact)
                }
            } else {
                try repository.insert(contact)
            }
            return contact.id
        }
    }

    public func duplicateCandidates() throws -> [DuplicateCandidate] {
        let all = try persons()
        var result: [DuplicateCandidate] = []
        for (index, first) in all.enumerated() {
            for second in all.dropFirst(index + 1) {
                let reasons = Rules.duplicateReasons(first, second)
                if !reasons.isEmpty { result.append(DuplicateCandidate(firstID: first.id, secondID: second.id, reasons: reasons)) }
            }
        }
        return result
    }

    public func merge(survivorID: UUID, removedID: UUID) throws -> UUID {
        guard survivorID != removedID else { throw StoreError.invalid("Нельзя объединить контакт с собой.") }
        return try write { repository in
            guard let survivor = try repository.person(id: survivorID),
                let removed = try repository.person(id: removedID)
            else { throw StoreError.missingPerson }
            let merged = Rules.merged(survivor, absorbing: removed)
            let record = MergeRecord(survivorBefore: survivor, removedBefore: removed, expectedRevision: merged.revision)
            try repository.delete(contactID: removed.id)
            try repository.update(merged)
            try repository.insert(record)
            return record.id
        }
    }

    public func mergeHistory() throws -> [MergeRecord] {
        try read { try $0.allMerges() }.sorted { $0.mergedAt > $1.mergedAt }
    }

    public func undoMerge(id: UUID) throws {
        try write { repository in
            guard var record = try repository.merge(id: id), record.undoneAt == nil,
                let current = try repository.person(id: record.survivorBefore.id),
                current.revision == record.expectedRevision,
                try repository.person(id: record.removedBefore.id) == nil
            else { throw StoreError.undoConflict }
            let revision = current.revision + 1
            var survivor = record.survivorBefore, removed = record.removedBefore
            survivor.revision = revision
            removed.revision = max(revision, removed.revision + 1)
            survivor.events.append(PersonEvent(kind: "undoMerge", detail: "Объединение отменено"))
            removed.events.append(PersonEvent(kind: "undoMerge", detail: "Контакт восстановлен"))
            try repository.update(survivor)
            try repository.insert(removed)
            record.undoneAt = Date()
            try repository.update(record)
        }
    }

    private func read<T>(_ body: (PersonRecordRepository) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try repository.read { try body(repository) }
    }

    private func write<T>(_ body: (PersonRecordRepository) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try repository.write { try body(repository) }
    }
}

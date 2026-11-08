import Foundation

/// Two persons the user pulled apart; auto-merge never joins them again.
public struct NoMergePair: Hashable, Codable, Sendable {
    public let first: UUID
    public let second: UUID
    public init(_ a: UUID, _ b: UUID) {
        if a.uuidString < b.uuidString {
            first = a
            second = b
        } else {
            first = b
            second = a
        }
    }
}

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

    /// Active persons (not deleted, not hidden as spam), sorted by name.
    public func persons() throws -> [Person] {
        try allPersons(includingInactive: false)
    }

    public func allPersons(includingInactive: Bool) throws -> [Person] {
        Self.sorted(try read { includingInactive ? try $0.allPersons() : try $0.activePersons() })
    }

    /// Active persons whose name, company, title, address, phone or username contains `query`.
    public func summaries(matching query: String, limit: Int) throws -> [PersonSummary] {
        let needle = Rules.trimmed(query)
        let all = Self.sorted(try read { try $0.activePersons() })
        let matched =
            needle.isEmpty
            ? all
            : all.filter { person in
                ([person.displayName, person.organization, person.jobTitle] + person.emails + person.phones + person.usernames)
                    .contains { $0.localizedCaseInsensitiveContains(needle) }
            }
        return matched.prefix(max(0, min(limit, 2000))).map(\.summary)
    }

    private static func sorted(_ persons: [Person]) -> [Person] {
        persons.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    /// Tests reach rows the public API does not yet write (deletion arrives with its own command).
    var repositoryForTests: PersonRecordRepository { repository }

    public func person(id: UUID) throws -> Person? {
        try read { try $0.person(id: id) }
    }

    public func createPerson(draft: PersonDraft) throws -> UUID {
        try Rules.validate(draft)
        return try write { repository in
            var contact = Person(displayName: Rules.trimmed(draft.displayName))
            Rules.apply(draft, to: &contact)
            // Only what the user typed is manual: empty scalars stay open to sources.
            contact.manualFields = Set(
                Rules.scalarFields.filter { field in
                    switch field {
                    case "displayName": !contact.displayName.isEmpty
                    case "givenName": !contact.givenName.isEmpty
                    case "familyName": !contact.familyName.isEmpty
                    case "middleName": !contact.middleName.isEmpty
                    case "organization": !contact.organization.isEmpty
                    default: !contact.jobTitle.isEmpty
                    }
                })
            Rules.recordManualChanges(from: nil, contact: &contact)
            contact.events.append(
                PersonEvent(
                    kind: "created", detail: contact.kind == .organization ? "Организация создана вручную" : "Персона создана вручную"))
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
            if before.givenName != after.givenName { contact.manualFields.insert("givenName") }
            if before.familyName != after.familyName { contact.manualFields.insert("familyName") }
            if before.middleName != after.middleName { contact.manualFields.insert("middleName") }
            if before.organization != after.organization { contact.manualFields.insert("organization") }
            if before.jobTitle != after.jobTitle { contact.manualFields.insert("jobTitle") }
            Rules.recordManualChanges(from: before, contact: &contact)
            contact.revision += 1
            contact.events.append(PersonEvent(kind: "edited", detail: "Изменено вручную"))
            try repository.update(contact)
        }
    }

    /// Moves a current list value to the former values; sources will not bring it back.
    public func removeValue(personID: UUID, field: PersonListField, value: String, reason: FormerReason) throws {
        try write { repository in
            guard var contact = try repository.person(id: personID) else { throw StoreError.missingPerson }
            guard Rules.retire(field: field, value: value, reason: reason, at: Date(), contact: &contact) else { return }
            contact.revision += 1
            let detail: String =
                switch reason {
                case .removedByUser: "Значение убрано: \(value)"
                case .removedInBook(let book): "Значение убрано во внешней книге \(book.service): \(value)"
                case .replacedByMerge: "Значение заменено при объединении: \(value)"
                }
            contact.events.append(PersonEvent(kind: "valueRemoved", detail: detail))
            try repository.update(contact)
        }
    }

    /// Brings a former value back as a manual entry.
    public func restoreValue(personID: UUID, field: PersonListField, value: String) throws {
        try write { repository in
            guard var contact = try repository.person(id: personID) else { throw StoreError.missingPerson }
            guard Rules.restore(field: field, value: value, contact: &contact) else { return }
            contact.revision += 1
            contact.events.append(PersonEvent(kind: "valueRestored", detail: "Значение возвращено: \(value)"))
            try repository.update(contact)
        }
    }

    /// Confirming a proposed observation makes its value current; proposals never return to observed.
    public func setObservationStatus(personID: UUID, observationID: UUID, status: ObservationStatus) throws {
        guard status == .confirmed else { throw StoreError.invalid("Предложенное наблюдение можно только принять или отклонить.") }
        try write { repository in
            guard var contact = try repository.person(id: personID) else { throw StoreError.missingPerson }
            guard let index = contact.observations.firstIndex(where: { $0.id == observationID }) else {
                throw StoreError.invalid("Наблюдение не найдено.")
            }
            guard contact.observations[index].status == .proposed else {
                throw StoreError.invalid("Наблюдение уже не является предложением.")
            }
            contact.observations[index].status = .confirmed
            let observation = contact.observations[index]
            if let field = PersonListField(rawValue: observation.field) {
                if !Rules.isFormer(contact, field: field, value: observation.value) {
                    contact.setValues(Rules.union(contact.values(field), [observation.value]), for: field)
                }
            } else if !contact.manualFields.contains(observation.field) {
                Rules.setScalar(observation.field, observation.value, contact: &contact)
            }
            contact.revision += 1
            contact.events.append(PersonEvent(kind: "observationConfirmed", detail: "Принято предложение: \(observation.value)"))
            try repository.update(contact)
        }
    }

    public func rejectProposedObservation(personID: UUID, observationID: UUID) throws {
        try write { repository in
            guard var contact = try repository.person(id: personID) else { throw StoreError.missingPerson }
            guard let index = contact.observations.firstIndex(where: { $0.id == observationID }) else {
                throw StoreError.invalid("Наблюдение не найдено.")
            }
            guard contact.observations[index].status == .proposed else { throw StoreError.invalid("Отклонить можно только предложение.") }
            let value = contact.observations[index].value
            contact.observations.remove(at: index)
            contact.revision += 1
            contact.events.append(PersonEvent(kind: "observationRejected", detail: "Отклонено предложение: \(value)"))
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

    // MARK: Organizations

    public func createOrganization(name: String) throws -> UUID {
        try createPerson(draft: PersonDraft(kind: .organization, displayName: name))
    }

    /// Active organizations by name.
    public func organizations() throws -> [Person] {
        try persons().filter { $0.kind == .organization }
    }

    /// An active organization with this name, ignoring case and surrounding spaces.
    public func organization(named name: String) throws -> Person? {
        let needle = Rules.trimmed(name)
        guard !needle.isEmpty else { return nil }
        return try organizations().first { $0.displayName.caseInsensitiveCompare(needle) == .orderedSame }
    }

    public func memberships(of personID: UUID, includingRemoved: Bool = false) throws -> [PersonMembership] {
        try read { try $0.memberships(personID: personID) }.filter { includingRemoved || $0.state != .removed }
    }

    public func allMemberships(includingRemoved: Bool) throws -> [PersonMembership] {
        try read { try $0.allMemberships() }.filter { includingRemoved || $0.state != .removed }
    }

    /// Persons (active or not) whose identities include `identity`.
    public func personsOwning(_ identity: ServiceIdentity) throws -> [Person] {
        try read { try $0.persons(owning: identity) }
    }

    public func members(of organizationID: UUID, includingRemoved: Bool = false) throws -> [PersonMembership] {
        try read { try $0.memberships(organizationID: organizationID) }.filter { includingRemoved || $0.state != .removed }
    }

    /// Nil when the pair already has a membership in any state: a removed one is never proposed again.
    public func suggestMembership(
        personID: UUID, organizationID: UUID, role: String, origin: MembershipOrigin
    ) throws
        -> PersonMembership?
    {
        try write { repository in
            guard var person = try repository.person(id: personID), var organization = try repository.person(id: organizationID) else {
                throw StoreError.missingPerson
            }
            guard person.kind == .person, organization.kind == .organization else {
                throw StoreError.invalid("В организацию входят только люди, и только в организацию.")
            }
            guard !(try repository.memberships(personID: personID)).contains(where: { $0.organizationID == organizationID }) else {
                return nil
            }
            let state: MembershipState = origin == .manual ? .confirmed : .suggested
            let membership = PersonMembership(
                organizationID: organizationID, personID: personID, role: Rules.trimmed(role), origin: origin, state: state)
            try repository.upsert(membership)
            person.revision += 1
            person.events.append(
                PersonEvent(
                    kind: state == .confirmed ? "membershipConfirmed" : "membershipSuggested",
                    detail: (state == .confirmed ? "Добавлено в организацию " : "Предложена организация ") + organization.displayName))
            try repository.update(person)
            organization.revision += 1
            organization.events.append(PersonEvent(kind: "memberAdded", detail: "Член организации: " + person.displayName))
            try repository.update(organization)
            return membership
        }
    }

    public func setMembershipState(id: UUID, state: MembershipState) throws {
        try write { repository in
            guard var membership = try repository.membership(id: id) else { throw StoreError.invalid("Членство не найдено.") }
            guard PersonMembership.allows(membership.state, state) else {
                throw StoreError.invalid("Недопустимый переход состояния членства.")
            }
            membership.state = state
            membership.updatedAt = Date()
            try repository.upsert(membership)
            guard var person = try repository.person(id: membership.personID) else { return }
            let organization = try repository.person(id: membership.organizationID)?.displayName ?? "организация"
            person.revision += 1
            person.events.append(
                PersonEvent(
                    kind: state == .removed ? "membershipRemoved" : "membershipConfirmed",
                    detail: (state == .removed ? "Убрано из организации " : "Подтверждена организация ") + organization))
            try repository.update(person)
        }
    }

    public func setMembershipRole(id: UUID, role: String) throws {
        try write { repository in
            guard var membership = try repository.membership(id: id) else { throw StoreError.invalid("Членство не найдено.") }
            membership.role = Rules.trimmed(role)
            membership.updatedAt = Date()
            try repository.upsert(membership)
        }
    }

    /// Pairs of active persons of one kind sharing a phone or an address, from the value index.
    public func duplicateCandidates() throws -> [DuplicateCandidate] {
        try read { repository in
            let kinds = Dictionary(uniqueKeysWithValues: try repository.activePersons().map { ($0.id, $0.kind) })
            let blocked = try repository.noMergePairs()
            var reasons: [NoMergePair: Set<String>] = [:]
            for shared in try repository.sharedValues() {
                let ids = shared.personIDs.filter { kinds[$0] != nil }
                for (index, first) in ids.enumerated() {
                    for second in ids.dropFirst(index + 1) where kinds[first] == kinds[second] {
                        let pair = NoMergePair(first, second)
                        guard !blocked.contains(pair) else { continue }
                        reasons[pair, default: []].insert(shared.field == "emails" ? "Совпадает email" : "Совпадает телефон")
                    }
                }
            }
            return reasons.map { pair, reasons in
                DuplicateCandidate(firstID: pair.first, secondID: pair.second, reasons: reasons.sorted())
            }.sorted { ($0.firstID.uuidString, $0.secondID.uuidString) < ($1.firstID.uuidString, $1.secondID.uuidString) }
        }
    }

    /// Another active person of the same kind sharing an exact phone or address that at most two
    /// persons hold, which is not a role address and not a pair the user pulled apart. Several → the oldest.
    public func autoMergeCandidate(for personID: UUID) throws -> UUID? {
        try read { repository in try autoMergeMatch(for: personID, repository: repository)?.otherID }
    }

    private func autoMergeMatch(
        for personID: UUID, repository: PersonRecordRepository
    ) throws -> (otherID: UUID, field: String, raw: String)? {
        guard let person = try repository.person(id: personID), person.isActive else { return nil }
        let blocked = try repository.noMergePairs()
        var candidates: [(otherID: UUID, field: String, raw: String, created: Date)] = []
        for match in try repository.valueMatches(personID: personID) where match.holders <= 2 {
            if match.field == "emails", PersonMatching.isRoleAddress(match.raw) { continue }
            guard !blocked.contains(NoMergePair(personID, match.otherID)), !candidates.contains(where: { $0.otherID == match.otherID }),
                let other = try repository.person(id: match.otherID), other.isActive, other.kind == person.kind
            else { continue }
            candidates.append((match.otherID, match.field, match.raw, Self.createdAt(other)))
        }
        return candidates.min { ($0.created, $0.otherID.uuidString) < ($1.created, $1.otherID.uuidString) }
            .map { ($0.otherID, $0.field, $0.raw) }
    }

    static func createdAt(_ person: Person) -> Date { person.createdAt }

    /// One automatic merge for this person, if an exact match exists: the older person survives.
    public func autoMerge(personID: UUID) throws -> UUID? {
        try write { repository in
            guard let match = try autoMergeMatch(for: personID, repository: repository),
                let person = try repository.person(id: personID), let other = try repository.person(id: match.otherID)
            else { return nil }
            let personFirst = (Self.createdAt(person), person.id.uuidString) <= (Self.createdAt(other), other.id.uuidString)
            let survivor = personFirst ? person : other, removed = personFirst ? other : person
            var merged = Rules.merged(survivor, absorbing: removed)
            let record = MergeRecord(survivorBefore: survivor, removedBefore: removed, expectedRevision: merged.revision)
            merged.events.append(
                PersonEvent(
                    kind: "autoMerged",
                    detail: "Склеено автоматически: совпал " + (match.field == "emails" ? "адрес " : "телефон ") + match.raw))
            try moveMemberships(from: removed, to: survivor, repository: repository)
            try repository.delete(contactID: removed.id)
            try repository.update(merged)
            try repository.insert(record)
            return survivor.id
        }
    }

    /// Joins two persons of one kind without further conditions: this is also «склеить принудительно».
    public func merge(survivorID: UUID, removedID: UUID) throws -> UUID {
        guard survivorID != removedID else { throw StoreError.invalid("Нельзя объединить персону с собой.") }
        return try write { repository in
            guard let survivor = try repository.person(id: survivorID),
                let removed = try repository.person(id: removedID)
            else { throw StoreError.missingPerson }
            guard survivor.kind == removed.kind else { throw StoreError.invalid("Нельзя объединить человека с организацией.") }
            let merged = Rules.merged(survivor, absorbing: removed)
            let record = MergeRecord(survivorBefore: survivor, removedBefore: removed, expectedRevision: merged.revision)
            try moveMemberships(from: removed, to: survivor, repository: repository)
            try repository.delete(contactID: removed.id)
            try repository.update(merged)
            try repository.insert(record)
            return record.id
        }
    }

    /// Memberships of the absorbed person (or organization) follow the survivor; a pair the
    /// survivor already has is kept once, the duplicate is marked removed.
    private func moveMemberships(from removed: Person, to survivor: Person, repository: PersonRecordRepository) throws {
        let own = try repository.memberships(personID: survivor.id) + repository.memberships(organizationID: survivor.id)
        for var membership in try repository.memberships(personID: removed.id) + repository.memberships(organizationID: removed.id) {
            if membership.personID == removed.id { membership.personID = survivor.id }
            if membership.organizationID == removed.id { membership.organizationID = survivor.id }
            let duplicate = own.contains { $0.personID == membership.personID && $0.organizationID == membership.organizationID }
            if duplicate && membership.state != .removed { membership.state = .removed }
            membership.updatedAt = Date()
            try repository.upsert(membership)
        }
    }

    /// Moves one source identity, with its observations and notes, into a new person. The
    /// original keeps every manual field and value; the pair is remembered as «не склеивать».
    public func detachIdentity(personID: UUID, identity: ServiceIdentity) throws -> UUID {
        try write { repository in
            guard var original = try repository.person(id: personID) else { throw StoreError.missingPerson }
            guard original.identities.contains(identity) else { throw StoreError.invalid("Источник не принадлежит этой персоне.") }
            guard original.identities.count > 1 || !original.manualFields.isEmpty || !original.manualValues.isEmpty else {
                throw StoreError.invalid("Нечего отделять: это единственный источник персоны.")
            }
            let moved = original.observations.filter { $0.source.identity == identity }
            let movedNotes = original.notes.filter { $0.source.identity == identity }
            func latest(_ field: String) -> String? {
                moved.filter { $0.field == field && $0.status != .proposed }.max { $0.source.fetchedAt < $1.source.fetchedAt }?.value
            }
            var detached = Person(displayName: latest("displayName") ?? identity.externalID, identities: [identity], observations: moved)
            detached.kind = original.kind
            detached.givenName = latest("givenName") ?? ""
            detached.familyName = latest("familyName") ?? ""
            detached.middleName = latest("middleName") ?? ""
            detached.organization = latest("organization") ?? ""
            detached.jobTitle = latest("jobTitle") ?? ""
            detached.notes = movedNotes
            for field in PersonListField.allCases {
                detached.setValues(
                    Rules.unique(moved.filter { $0.field == field.rawValue && $0.status != .proposed }.map(\.value)), for: field)
            }
            original.identities.removeAll { $0 == identity }
            original.observations.removeAll { $0.source.identity == identity }
            original.notes.removeAll { $0.source.identity == identity }
            for field in PersonListField.allCases {
                let kept = original.values(field).filter { value in
                    original.manualValues.contains(ManualValue(field: field.rawValue, value: value))
                        || original.observations.contains { $0.field == field.rawValue && $0.value == value && $0.status != .proposed }
                }
                original.setValues(kept, for: field)
            }
            original.revision += 1
            original.events.append(PersonEvent(kind: "identityDetached", detail: "Источник \(identity.service) отделён в новую персону"))
            detached.events.append(PersonEvent(kind: "identityDetached", detail: "Отделено от персоны \(original.displayName)"))
            try repository.update(original)
            try repository.insert(detached)
            try repository.insert(NoMergePair(original.id, detached.id))
            return detached.id
        }
    }

    // MARK: Lifecycle

    /// Soft deletion: the person leaves the lists and the value index but keeps its identities,
    /// so a later observation lands here instead of creating a second person.
    public func deletePerson(id: UUID) throws {
        try write { repository in
            guard var person = try repository.person(id: id) else { throw StoreError.missingPerson }
            guard person.deletedAt == nil else { return }
            person.deletedAt = Date()
            person.revision += 1
            person.events.append(PersonEvent(kind: "deleted", detail: "Персона удалена"))
            try repository.update(person)
        }
    }

    public func restorePerson(id: UUID) throws {
        try write { repository in
            guard var person = try repository.person(id: id) else { throw StoreError.missingPerson }
            guard person.deletedAt != nil else { return }
            person.deletedAt = nil
            person.revision += 1
            person.events.append(PersonEvent(kind: "restored", detail: "Персона восстановлена"))
            try repository.update(person)
        }
    }

    /// A person whose only evidence turned out to be spam is hidden; its suggested memberships are withdrawn.
    public func setHiddenAsSpam(id: UUID, _ hidden: Bool) throws {
        try write { repository in
            guard var person = try repository.person(id: id) else { throw StoreError.missingPerson }
            guard person.hiddenAsSpam != hidden else { return }
            person.hiddenAsSpam = hidden
            person.revision += 1
            person.events.append(
                PersonEvent(kind: hidden ? "hiddenAsSpam" : "unhidden", detail: hidden ? "Скрыта как спам" : "Больше не считается спамом"))
            try repository.update(person)
            guard hidden else { return }
            for var membership in try repository.memberships(personID: id) where membership.state == .suggested {
                membership.state = .removed
                membership.updatedAt = Date()
                try repository.upsert(membership)
            }
        }
    }

    public func recordMailEvidence(accountID: String, address: String, spam: Bool) throws -> (clean: Int, spam: Int) {
        try write { try $0.recordMailEvidence(accountID: accountID, address: PersonMatching.normalizedEmail(address), spam: spam) }
    }

    public func mailEvidence(address: String) throws -> (clean: Int, spam: Int) {
        try read { try $0.mailEvidence(address: PersonMatching.normalizedEmail(address)) }
    }

    /// Clears the flag that this source account set; flags the user set stay.
    public func clearAddressBook(fromSource source: ImportSource) throws -> [UUID] {
        try write { repository in
            var cleared: [UUID] = []
            for var person in try repository.allPersons() where person.addressBookOrigin == .sourceAccount(source) {
                person.addressBook = false
                person.addressBookOrigin = nil
                person.revision += 1
                person.events.append(
                    PersonEvent(kind: "addressBookOff", detail: "Учётная запись \(source.service) больше не адресная книга"))
                try repository.update(person)
                cleared.append(person.id)
            }
            return cleared
        }
    }

    public func noMergePairs() throws -> Set<NoMergePair> {
        try read { try $0.noMergePairs() }
    }

    /// Sets or clears the address-book flag. A flag the user set outlives flags from source accounts.
    public func setAddressBook(personID: UUID, _ on: Bool, origin: AddressBookOrigin) throws {
        try write { repository in
            guard var person = try repository.person(id: personID) else { throw StoreError.missingPerson }
            if on {
                guard !person.hiddenAsSpam else { throw StoreError.invalid("Персона скрыта как спам.") }
                let newOrigin: AddressBookOrigin = person.addressBookOrigin == .user ? .user : origin
                guard !(person.addressBook && person.addressBookOrigin == newOrigin) else { return }
                person.addressBook = true
                person.addressBookOrigin = newOrigin
                person.events.append(PersonEvent(kind: "addressBookOn", detail: "Включена адресная книга"))
            } else {
                guard person.addressBook || person.addressBookOrigin != nil else { return }
                person.addressBook = false
                person.addressBookOrigin = nil
                person.events.append(PersonEvent(kind: "addressBookOff", detail: "Выключена адресная книга"))
            }
            person.revision += 1
            try repository.update(person)
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

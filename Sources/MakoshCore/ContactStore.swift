import Foundation
import CPostgres

/// Local PostgreSQL persistence. Each mutation reloads the versioned state while
/// holding a row lock; independent app connections cannot overwrite stale state.
public final class ContactStore {
    private struct State: Codable {
        var contacts: [Contact] = []
        var merges: [MergeRecord] = []
        var fetched: [String: Date] = [:]
    }
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    private let table: String

    public init(connectionString: String, schema: String = "makosh") throws {
        let bytes = Array(schema.utf8)
        guard !bytes.isEmpty, bytes.count <= 63, (97...122).contains(bytes[0]),
              bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw StoreError.invalid("Недопустимое имя схемы PostgreSQL.")
        }
        guard !connectionString.utf8.contains(0) else {
            throw StoreError.invalid("Недопустимая строка подключения PostgreSQL.")
        }
        table = "\"\(schema)\".state"
        db = Self.connect(connectionString)
        guard let db, PQstatus(db) == CONNECTION_OK else {
            if let db { PQfinish(db) }; self.db = nil
            throw StoreError.database("PostgreSQL connection failed.")
        }
        // Notices can contain server-provided data. Do not forward them to logs.
        PQsetNoticeProcessor(db, { _, _ in }, nil)
        do {
            try execute("SET client_encoding TO 'UTF8'")
            try execute("SET statement_timeout TO '15s'")
            try execute("SET lock_timeout TO '5s'")
            try execute("BEGIN")
            do {
                // Serialize initial creation for two connections opening the same schema.
                try execute("SELECT pg_advisory_xact_lock(hashtext('makosh-schema'), hashtext('\(schema)'))")
                try execute("CREATE SCHEMA IF NOT EXISTS \"\(schema)\"")
                try execute("CREATE TABLE IF NOT EXISTS \(table) (id SMALLINT PRIMARY KEY CHECK (id=1), schema_version INTEGER NOT NULL, payload JSONB NOT NULL)")
                let initial = try encoded(State())
                try execute("INSERT INTO \(table) (id, schema_version, payload) VALUES (1,1,$1::jsonb) ON CONFLICT (id) DO NOTHING", parameter: initial)
                _ = try load(forUpdate: true)
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        } catch { PQfinish(db); self.db = nil; throw error }
    }
    deinit { if let db { PQfinish(db) } }

    private static func connect(_ connectionString: String) -> OpaquePointer? {
        // Later parameter overrides enforce a finite timeout for both URI and keyword DSNs.
        connectionString.withCString { dsn in
            "dbname".withCString { databaseKey in
                "connect_timeout".withCString { timeoutKey in
                    "5".withCString { timeout in
                        let keys: [UnsafePointer<CChar>?] = [databaseKey, timeoutKey, nil]
                        let values: [UnsafePointer<CChar>?] = [dsn, timeout, nil]
                        return keys.withUnsafeBufferPointer { keys in
                            values.withUnsafeBufferPointer { values in
                                PQconnectdbParams(keys.baseAddress, values.baseAddress, 1)
                            }
                        }
                    }
                }
            }
        }
    }

    public func contacts() throws -> [Contact] {
        lock.lock(); defer { lock.unlock() }
        return try load().contacts.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }
    public func contact(id: UUID) throws -> Contact? {
        lock.lock(); defer { lock.unlock() }
        return try load().contacts.first { $0.id == id }
    }
    public func createContact(draft: ContactDraft) throws -> UUID {
        try validate(draft)
        return try mutate { state in
            var contact = Contact(displayName: trimmed(draft.displayName))
            apply(draft, to: &contact)
            contact.manualFields = ["displayName", "organization", "jobTitle", "phones", "emails", "tags"]
            recordManualChanges(from: nil, contact: &contact)
            contact.events.append(ContactEvent(kind: "created", detail: "Контакт создан вручную"))
            state.contacts.append(contact)
            return contact.id
        }
    }
    public func updateContact(id: UUID, draft: ContactDraft) throws {
        try validate(draft)
        try mutate { state in
            guard let index = state.contacts.firstIndex(where: { $0.id == id }) else { throw StoreError.missingContact }
            var contact = state.contacts[index]
            let before = contact.draft
            apply(draft, to: &contact)
            let after = contact.draft
            guard before != after else { return }
            if before.displayName != after.displayName { contact.manualFields.insert("displayName") }
            if before.organization != after.organization { contact.manualFields.insert("organization") }
            if before.jobTitle != after.jobTitle { contact.manualFields.insert("jobTitle") }
            if before.phones != after.phones { contact.manualFields.insert("phones") }
            if before.emails != after.emails { contact.manualFields.insert("emails") }
            if before.tags != after.tags { contact.manualFields.insert("tags") }
            recordManualChanges(from: before, contact: &contact)
            contact.revision += 1
            contact.events.append(ContactEvent(kind: "edited", detail: "Изменено вручную"))
            state.contacts[index] = contact
        }
    }
    public func addNote(contactID: UUID, text: String) throws {
        guard !trimmed(text).isEmpty else { throw StoreError.invalid("Заметка не может быть пустой.") }
        try mutate { state in
            guard let index = state.contacts.firstIndex(where: { $0.id == contactID }) else { throw StoreError.missingContact }
            let identity = ServiceIdentity(service: "manual", accountID: "local", externalID: contactID.uuidString)
            state.contacts[index].notes.append(ContactNote(text: trimmed(text), source: SourceStamp(identity: identity)))
            state.contacts[index].revision += 1
            state.contacts[index].events.append(ContactEvent(kind: "note", detail: "Добавлена заметка"))
        }
    }
    public func importJSON(data: Data) throws -> ImportResult {
        try importDocument(ImportDocument.decode(data))
    }
    public func importDocument(_ document: ImportDocument) throws -> ImportResult {
        guard document.schemaVersion == 1 else { throw StoreError.unsupportedSchema(document.schemaVersion) }
        guard !trimmed(document.source.service).isEmpty, !trimmed(document.source.accountID).isEmpty,
              document.fetchedAt.timeIntervalSince1970.isFinite else { throw StoreError.invalid("Укажите источник, аккаунт и дату импорта.") }
        var keys = Set<String>()
        for incoming in document.contacts {
            guard !trimmed(incoming.externalID).isEmpty else { throw StoreError.invalid("Отсутствует внешний идентификатор.") }
            try validate(ContactDraft(displayName: incoming.displayName))
            let identity = ServiceIdentity(service: document.source.service, accountID: document.source.accountID, externalID: incoming.externalID)
            guard keys.insert(identity.id).inserted else { throw StoreError.invalid("Повтор внешнего идентификатора в одном импорте.") }
        }
        return try mutate { state in
            var result = ImportResult(created: 0, updated: 0)
            for incoming in document.contacts {
                let identity = ServiceIdentity(service: document.source.service, accountID: document.source.accountID, externalID: incoming.externalID)
                if let previous = state.fetched[identity.id], document.fetchedAt < previous { continue }
                let stamp = SourceStamp(identity: identity, fetchedAt: document.fetchedAt)
                let index = state.contacts.firstIndex { $0.identities.contains(identity) }
                var contact = index.map { state.contacts[$0] } ?? Contact(displayName: trimmed(incoming.displayName), identities: [identity])
                let before = contact
                absorb(incoming, source: stamp, into: &contact)
                state.fetched[identity.id] = max(state.fetched[identity.id] ?? document.fetchedAt, document.fetchedAt)
                if let index {
                    if contact != before {
                        contact.revision += 1
                        if contentWithoutFetchDates(contact) != contentWithoutFetchDates(before) {
                            contact.events.append(ContactEvent(date: document.fetchedAt, kind: "import", detail: "Обновлено из \(identity.service)"))
                        }
                        state.contacts[index] = contact; result.updated += 1
                    }
                } else {
                    contact.events.append(ContactEvent(date: document.fetchedAt, kind: "import", detail: "Импортировано из \(identity.service)"))
                    state.contacts.append(contact); result.created += 1
                }
            }
            return result
        }
    }
    /// Explicitly attaches a source identity without moving it between contacts.
    @discardableResult
    public func linkImportedContact(_ incoming: ImportedContact, source: ImportSource,
                                    fetchedAt: Date, contactID: UUID?) throws -> UUID {
        guard !trimmed(source.service).isEmpty, !trimmed(source.accountID).isEmpty,
              !trimmed(incoming.externalID).isEmpty, fetchedAt.timeIntervalSince1970.isFinite else {
            throw StoreError.invalid("Некорректные данные привязки контакта.")
        }
        try validate(ContactDraft(displayName: incoming.displayName))
        let identity = ServiceIdentity(service: source.service, accountID: source.accountID, externalID: incoming.externalID)
        return try mutate { state in
            let owners = state.contacts.indices.filter { state.contacts[$0].identities.contains(identity) }
            guard owners.count <= 1,
                  owners.allSatisfy({ state.contacts[$0].identities.filter { $0 == identity }.count == 1 }) else {
                throw StoreError.invalid("Неоднозначная привязка источника контакта.")
            }
            let index: Int?
            if let contactID {
                guard let target = state.contacts.firstIndex(where: { $0.id == contactID }),
                      owners.first == nil || owners.first == target else {
                    throw StoreError.invalid("Не удалось привязать источник к выбранному контакту.")
                }
                index = target
            } else { index = owners.first }
            var contact = index.map { state.contacts[$0] } ?? Contact(displayName: trimmed(incoming.displayName))
            let before = contact
            let attached = !contact.identities.contains(identity)
            if attached { contact.identities.append(identity) }
            let previousFetched = state.fetched[identity.id]
            let stale = previousFetched.map { fetchedAt < $0 } ?? false
            if !stale {
                absorb(incoming, source: SourceStamp(identity: identity, fetchedAt: fetchedAt), into: &contact)
                state.fetched[identity.id] = max(previousFetched ?? fetchedAt, fetchedAt)
            }
            let sourceChanged = state.fetched[identity.id] != previousFetched
            if attached {
                contact.events.append(ContactEvent(date: fetchedAt, kind: "identityLink", detail: "Привязан источник контакта"))
            } else if contentWithoutFetchDates(contact) != contentWithoutFetchDates(before) {
                contact.events.append(ContactEvent(date: fetchedAt, kind: "import", detail: "Обновлено из источника контакта"))
            }
            if let index {
                if contact != before || sourceChanged {
                    contact.revision += 1
                    state.contacts[index] = contact
                }
            } else { state.contacts.append(contact) }
            return contact.id
        }
    }

    public func duplicateCandidates() throws -> [DuplicateCandidate] {
        let all = try contacts()
        var result: [DuplicateCandidate] = []
        for (index, first) in all.enumerated() {
            for second in all.dropFirst(index + 1) {
                var reasons: [String] = []
                let emails = Set(first.emails.map(normalizedEmail).filter { !$0.isEmpty })
                    .intersection(second.emails.map(normalizedEmail).filter { !$0.isEmpty })
                let phones = Set(first.phones.map(normalizedPhone).filter { !$0.isEmpty })
                    .intersection(second.phones.map(normalizedPhone).filter { !$0.isEmpty })
                if !emails.isEmpty { reasons.append("Совпадает email") }
                if !phones.isEmpty { reasons.append("Совпадает телефон") }
                if !reasons.isEmpty { result.append(DuplicateCandidate(firstID: first.id, secondID: second.id, reasons: reasons)) }
            }
        }
        return result
    }
    public func merge(survivorID: UUID, removedID: UUID) throws -> UUID {
        guard survivorID != removedID else { throw StoreError.invalid("Нельзя объединить контакт с собой.") }
        return try mutate { state in
            guard let survivorIndex = state.contacts.firstIndex(where: { $0.id == survivorID }),
                  let removedIndex = state.contacts.firstIndex(where: { $0.id == removedID }) else { throw StoreError.missingContact }
            let before = state.contacts[survivorIndex], removed = state.contacts[removedIndex]
            var merged = before
            if merged.displayName.isEmpty { merged.displayName = removed.displayName }
            if merged.organization.isEmpty { merged.organization = removed.organization }
            if merged.jobTitle.isEmpty { merged.jobTitle = removed.jobTitle }
            // Confirming a merge also confirms the chosen scalar when sources disagree.
            // Keep imported observations, but prevent re-import from undoing that choice.
            if before.displayName != removed.displayName { merged.manualFields.insert("displayName") }
            if before.organization != removed.organization { merged.manualFields.insert("organization") }
            if before.jobTitle != removed.jobTitle { merged.manualFields.insert("jobTitle") }
            merged.phones = union(merged.phones, removed.phones)
            merged.emails = union(merged.emails, removed.emails)
            merged.tags = union(merged.tags, removed.tags)
            merged.identities = union(merged.identities, removed.identities)
            // Keep every distinct observation from both histories, including conflicting scalar values.
            for observation in removed.observations {
                if !merged.observations.contains(where: { $0.field == observation.field && $0.value == observation.value && $0.source.identity == observation.source.identity && $0.source.fetchedAt == observation.source.fetchedAt }) {
                    merged.observations.append(observation)
                }
            }
            merged.notes = union(merged.notes, removed.notes)
            merged.events = union(merged.events, removed.events)
            merged.manualFields.formUnion(removed.manualFields)
            merged.revision = max(before.revision, removed.revision) + 1
            merged.events.append(ContactEvent(kind: "merge", detail: "Объединено с \(removed.displayName)"))
            let record = MergeRecord(survivorBefore: before, removedBefore: removed, expectedRevision: merged.revision)
            state.contacts[survivorIndex] = merged
            state.contacts.remove(at: removedIndex)
            state.merges.append(record)
            return record.id
        }
    }
    public func mergeHistory() throws -> [MergeRecord] {
        lock.lock(); defer { lock.unlock() }
        return try load().merges.sorted { $0.mergedAt > $1.mergedAt }
    }
    public func undoMerge(id: UUID) throws {
        try mutate { state in
            guard let recordIndex = state.merges.firstIndex(where: { $0.id == id }) else { throw StoreError.undoConflict }
            let record = state.merges[recordIndex]
            guard record.undoneAt == nil,
                  let index = state.contacts.firstIndex(where: { $0.id == record.survivorBefore.id }),
                  state.contacts[index].revision == record.expectedRevision,
                  !state.contacts.contains(where: { $0.id == record.removedBefore.id }) else { throw StoreError.undoConflict }
            let revision = state.contacts[index].revision + 1
            var survivor = record.survivorBefore, removed = record.removedBefore
            survivor.revision = revision
            removed.revision = max(revision, removed.revision + 1)
            survivor.events.append(ContactEvent(kind: "undoMerge", detail: "Объединение отменено"))
            removed.events.append(ContactEvent(kind: "undoMerge", detail: "Контакт восстановлен"))
            state.contacts[index] = survivor
            state.contacts.append(removed)
            state.merges[recordIndex].undoneAt = Date()
        }
    }

    private func contentWithoutFetchDates(_ contact: Contact) -> Contact {
        var copy = contact
        copy.revision = 0
        for index in copy.observations.indices { copy.observations[index].source.fetchedAt = Date(timeIntervalSince1970: 0) }
        for index in copy.notes.indices { copy.notes[index].source.fetchedAt = Date(timeIntervalSince1970: 0) }
        return copy
    }
    private func recordManualChanges(from before: ContactDraft?, contact: inout Contact) {
        let source = SourceStamp(identity: ServiceIdentity(service: "manual", accountID: "local", externalID: contact.id.uuidString))
        for (field, value, old) in [("displayName", contact.displayName, before?.displayName),
                                     ("organization", contact.organization, before?.organization),
                                     ("jobTitle", contact.jobTitle, before?.jobTitle)] {
            if old == nil || value != old { observe(field: field, value: value, source: source, contact: &contact) }
        }
        for (field, values, old) in [("phones", contact.phones, before?.phones),
                                    ("emails", contact.emails, before?.emails),
                                    ("tags", contact.tags, before?.tags)] {
            if old == nil || values != old {
                // Empty is an explicit manual clearance, retained in provenance.
                for value in values.isEmpty ? [""] : values { observe(field: field, value: value, source: source, contact: &contact) }
            }
        }
    }
    private func absorb(_ incoming: ImportedContact, source: SourceStamp, into contact: inout Contact) {
        let scalarFields: [(String, String?)] = [("displayName", incoming.displayName), ("organization", incoming.organization), ("jobTitle", incoming.jobTitle)]
        for (field, value) in scalarFields {
            guard let value else { continue }
            let cleaned = trimmed(value)
            let latest = contact.observations.filter { $0.field == field }.map(\.source.fetchedAt).max()
            observe(field: field, value: cleaned, source: source, contact: &contact)
            guard !contact.manualFields.contains(field), latest == nil || source.fetchedAt >= latest! else { continue }
            switch field {
            case "displayName": contact.displayName = cleaned
            case "organization": contact.organization = cleaned
            default: contact.jobTitle = cleaned
            }
        }
        for (field, values) in [("phones", incoming.phones), ("emails", incoming.emails), ("tags", incoming.tags)] {
            let cleaned = unique(values)
            for value in cleaned { observe(field: field, value: value, source: source, contact: &contact) }
            guard !contact.manualFields.contains(field) else { continue }
            switch field {
            case "phones": contact.phones = union(contact.phones, cleaned)
            case "emails": contact.emails = union(contact.emails, cleaned)
            default: contact.tags = union(contact.tags, cleaned)
            }
        }
        for text in unique(incoming.notes) {
            if let index = contact.notes.firstIndex(where: { $0.text == text && $0.source.identity == source.identity }) {
                if source.fetchedAt > contact.notes[index].source.fetchedAt { contact.notes[index].source.fetchedAt = source.fetchedAt }
            } else { contact.notes.append(ContactNote(text: text, source: source)) }
        }
    }
    private func observe(field: String, value: String, source: SourceStamp, contact: inout Contact) {
        if let index = contact.observations.firstIndex(where: { $0.field == field && $0.value == value && $0.source.identity == source.identity }) {
            if source.fetchedAt > contact.observations[index].source.fetchedAt { contact.observations[index].source.fetchedAt = source.fetchedAt }
        } else { contact.observations.append(Observation(field: field, value: value, source: source)) }
    }
    private func apply(_ draft: ContactDraft, to contact: inout Contact) {
        contact.displayName = trimmed(draft.displayName); contact.organization = trimmed(draft.organization); contact.jobTitle = trimmed(draft.jobTitle)
        contact.phones = unique(draft.phones); contact.emails = unique(draft.emails); contact.tags = unique(draft.tags)
    }
    private func validate(_ draft: ContactDraft) throws {
        guard !trimmed(draft.displayName).isEmpty else { throw StoreError.invalid("Укажите имя контакта.") }
    }
    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func unique(_ values: [String]) -> [String] { union([], values.map(trimmed).filter { !$0.isEmpty }) }
    private func union<T: Equatable>(_ first: [T], _ second: [T]) -> [T] {
        var result = first
        for value in second where !result.contains(value) { result.append(value) }
        return result
    }
    private func normalizedEmail(_ value: String) -> String { trimmed(value).lowercased() }
    private func normalizedPhone(_ value: String) -> String { value.filter { $0.isASCII && $0.isNumber } }

    private func mutate<T>(_ operation: (inout State) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN")
        do {
            var state = try load(forUpdate: true)
            let result = try operation(&state)
            try save(state)
            try execute("COMMIT")
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func databaseError(_ result: OpaquePointer?) -> StoreError {
        // PostgreSQL error DETAIL and message text may embed imported data or credentials.
        // Only expose the standardized five-character SQLSTATE, never libpq's raw message.
        if let result, let field = PQresultErrorField(result, Int32(MAKOSH_PG_DIAG_SQLSTATE)) {
            let code = String(cString: field)
            if code.utf8.count == 5, code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) {
                return .database("PostgreSQL operation failed (SQLSTATE \(code)).")
            }
        }
        return .database("PostgreSQL operation failed.")
    }
    private func query(_ sql: String, parameter: String? = nil) throws -> OpaquePointer {
        let result: OpaquePointer?
        if let parameter {
            result = parameter.withCString { value in
                var values: [UnsafePointer<CChar>?] = [value]
                return values.withUnsafeMutableBufferPointer { values in
                    PQexecParams(db, sql, 1, nil, values.baseAddress, nil, nil, 0)
                }
            }
        } else { result = PQexec(db, sql) }
        guard let result else { throw databaseError(nil) }
        let status = PQresultStatus(result)
        guard status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK else {
            let error = databaseError(result); PQclear(result); throw error
        }
        return result
    }
    private func execute(_ sql: String, parameter: String? = nil) throws {
        let result = try query(sql, parameter: parameter)
        PQclear(result)
    }
    private func load(forUpdate: Bool = false) throws -> State {
        let result = try query("SELECT schema_version, payload::text FROM \(table) WHERE id=1" + (forUpdate ? " FOR UPDATE" : ""))
        defer { PQclear(result) }
        guard PQntuples(result) == 1, PQgetisnull(result, 0, 0) == 0,
              let versionText = PQgetvalue(result, 0, 0), let version = Int(String(cString: versionText)) else {
            throw StoreError.database("PostgreSQL state row is missing or invalid.")
        }
        guard version == 1 else { throw StoreError.unsupportedSchema(version) }
        guard PQgetisnull(result, 0, 1) == 0, let text = PQgetvalue(result, 0, 1) else {
            throw StoreError.database("PostgreSQL state payload is missing.")
        }
        do { return try JSONDecoder().decode(State.self, from: Data(String(cString: text).utf8)) }
        catch { throw StoreError.database("PostgreSQL state payload is invalid.") }
    }
    private func encoded(_ state: State) throws -> String {
        do { return String(decoding: try JSONEncoder().encode(state), as: UTF8.self) }
        catch { throw StoreError.database("State encoding failed.") }
    }
    private func save(_ state: State) throws {
        let result = try query("UPDATE \(table) SET payload=$1::jsonb WHERE id=1 AND schema_version=1", parameter: try encoded(state))
        defer { PQclear(result) }
        guard let count = PQcmdTuples(result), String(cString: count) == "1" else {
            throw StoreError.database("PostgreSQL state update did not affect exactly one row.")
        }
    }
}

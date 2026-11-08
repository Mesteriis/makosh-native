import Foundation

/// Pure provenance rules shared by contact edits, imports and merges.
/// Manual fields suppress import writes; every observation is retained.
enum PersonReconciliation {
    static func contentWithoutFetchDates(_ contact: Person) -> Person {
        var copy = contact
        copy.revision = 0
        for index in copy.observations.indices { copy.observations[index].source.fetchedAt = Date(timeIntervalSince1970: 0) }
        for index in copy.notes.indices { copy.notes[index].source.fetchedAt = Date(timeIntervalSince1970: 0) }
        return copy
    }

    static let scalarFields = ["displayName", "givenName", "familyName", "middleName", "organization", "jobTitle"]

    static func manualSource(_ contact: Person) -> SourceStamp {
        SourceStamp(identity: ServiceIdentity(service: "manual", accountID: "local", externalID: contact.id.uuidString))
    }

    /// Scalars changed by hand become manual fields; list entries typed by hand become
    /// manual values, and entries the user dropped move to `former`.
    static func recordManualChanges(from before: PersonDraft?, contact: inout Person, at now: Date = Date()) {
        let source = manualSource(contact)
        for (field, value, old) in [
            ("displayName", contact.displayName, before?.displayName),
            ("givenName", contact.givenName, before?.givenName),
            ("familyName", contact.familyName, before?.familyName),
            ("middleName", contact.middleName, before?.middleName),
            ("organization", contact.organization, before?.organization),
            ("jobTitle", contact.jobTitle, before?.jobTitle),
        ] {
            // An empty scalar on creation is nothing typed, so it leaves no manual observation.
            if old == nil ? !value.isEmpty : value != old { observe(field: field, value: value, source: source, contact: &contact) }
        }
        for field in PersonListField.allCases {
            let values = contact.values(field)
            let old = before.map { draftValues($0, field) }
            guard old == nil || values != old else { continue }
            for value in values where !(old?.contains(value) ?? false) {
                observe(field: field.rawValue, value: value, source: source, contact: &contact)
                contact.manualValues.insert(ManualValue(field: field.rawValue, value: value))
            }
            for value in old ?? [] where !values.contains(value) {
                markFormer(field: field, value: value, reason: .removedByUser, at: now, contact: &contact)
            }
        }
    }

    static func draftValues(_ draft: PersonDraft, _ field: PersonListField) -> [String] {
        switch field {
        case .phones: unique(draft.phones)
        case .emails: unique(draft.emails)
        case .usernames: unique(draft.usernames)
        case .tags: unique(draft.tags)
        }
    }

    /// Moves a current list value into `former`; a value that is already former stays as it was.
    @discardableResult
    static func retire(field: PersonListField, value: String, reason: FormerReason, at now: Date, contact: inout Person) -> Bool {
        var values = contact.values(field)
        guard let index = values.firstIndex(of: value) else { return false }
        values.remove(at: index)
        contact.setValues(values, for: field)
        markFormer(field: field, value: value, reason: reason, at: now, contact: &contact)
        return true
    }

    /// Records a value as former (replacing an older former entry for the same value) and drops its manual mark.
    static func markFormer(field: PersonListField, value: String, reason: FormerReason, at now: Date, contact: inout Person) {
        contact.manualValues.remove(ManualValue(field: field.rawValue, value: value))
        contact.former.removeAll { $0.field == field.rawValue && $0.value == value }
        contact.former.append(FormerValue(field: field.rawValue, value: value, since: now, reason: reason))
    }

    /// Brings a former value back as a manual entry.
    static func restore(field: PersonListField, value: String, contact: inout Person) -> Bool {
        guard let index = contact.former.firstIndex(where: { $0.field == field.rawValue && $0.value == value }) else { return false }
        contact.former.remove(at: index)
        contact.setValues(union(contact.values(field), [value]), for: field)
        contact.manualValues.insert(ManualValue(field: field.rawValue, value: value))
        return true
    }

    static func isFormer(_ contact: Person, field: PersonListField, value: String) -> Bool {
        contact.former.contains { $0.field == field.rawValue && $0.value == value }
    }

    /// Sources add: scalars only when the field is not manual and the source is the newest;
    /// list entries always, except values the user retired, which stay former.
    static func absorb(_ incoming: ImportedPerson, source: SourceStamp, into contact: inout Person) {
        let scalarFields: [(String, String?)] = [
            ("displayName", incoming.displayName), ("givenName", incoming.givenName), ("familyName", incoming.familyName),
            ("middleName", incoming.middleName), ("organization", incoming.organization), ("jobTitle", incoming.jobTitle),
        ]
        for (field, value) in scalarFields {
            guard let value else { continue }
            let cleaned = trimmed(value)
            let latest = contact.observations.filter { $0.field == field && $0.status != .proposed }.map(\.source.fetchedAt).max()
            observe(field: field, value: cleaned, source: source, contact: &contact)
            guard !contact.manualFields.contains(field), latest.map({ source.fetchedAt >= $0 }) ?? true else { continue }
            setScalar(field, cleaned, contact: &contact)
        }
        for field in PersonListField.allCases {
            let cleaned = unique(importedValues(incoming, field))
            for value in cleaned { observe(field: field.rawValue, value: value, source: source, contact: &contact) }
            let additions = cleaned.filter { !isFormer(contact, field: field, value: $0) }
            contact.setValues(union(contact.values(field), additions), for: field)
        }
        for text in unique(incoming.notes) {
            if let index = contact.notes.firstIndex(where: { $0.text == text && $0.source.identity == source.identity }) {
                if source.fetchedAt > contact.notes[index].source.fetchedAt { contact.notes[index].source.fetchedAt = source.fetchedAt }
            } else {
                contact.notes.append(PersonNote(text: text, source: source))
            }
        }
    }

    /// Unions both histories. A confirmed merge also confirms the survivor's
    /// scalar choice, so re-import cannot silently reverse it.
    static func merged(_ survivor: Person, absorbing removed: Person) -> Person {
        var merged = survivor
        if merged.displayName.isEmpty { merged.displayName = removed.displayName }
        if merged.organization.isEmpty { merged.organization = removed.organization }
        if merged.jobTitle.isEmpty { merged.jobTitle = removed.jobTitle }
        if survivor.displayName != removed.displayName { merged.manualFields.insert("displayName") }
        if survivor.organization != removed.organization { merged.manualFields.insert("organization") }
        if survivor.jobTitle != removed.jobTitle { merged.manualFields.insert("jobTitle") }
        merged.phones = union(merged.phones, removed.phones)
        merged.emails = union(merged.emails, removed.emails)
        merged.tags = union(merged.tags, removed.tags)
        merged.identities = union(merged.identities, removed.identities)
        // Keep every distinct observation from both histories, including conflicting scalar values.
        for observation in removed.observations
        where !merged.observations.contains(where: {
            $0.field == observation.field && $0.value == observation.value
                && $0.source.identity == observation.source.identity && $0.source.fetchedAt == observation.source.fetchedAt
        }) {
            merged.observations.append(observation)
        }
        merged.notes = union(merged.notes, removed.notes)
        merged.events = union(merged.events, removed.events)
        merged.manualFields.formUnion(removed.manualFields)
        // A forbidden side stays forbidden; allowed only replaces inherit.
        if [survivor.aiAccess, removed.aiAccess].contains(.forbidden) {
            merged.aiAccess = .forbidden
        } else if [survivor.aiAccess, removed.aiAccess].contains(.allowed) {
            merged.aiAccess = .allowed
        }
        merged.revision = max(survivor.revision, removed.revision) + 1
        merged.events.append(PersonEvent(kind: "merge", detail: "Объединено с \(removed.displayName)"))
        return merged
    }

    static func duplicateReasons(_ first: Person, _ second: Person) -> [String] {
        let emails = Set(first.emails.map(normalizedEmail).filter { !$0.isEmpty })
            .intersection(second.emails.map(normalizedEmail).filter { !$0.isEmpty })
        let phones = Set(first.phones.map(normalizedPhone).filter { !$0.isEmpty })
            .intersection(second.phones.map(normalizedPhone).filter { !$0.isEmpty })
        var reasons: [String] = []
        if !emails.isEmpty { reasons.append("Совпадает email") }
        if !phones.isEmpty { reasons.append("Совпадает телефон") }
        return reasons
    }

    static func setScalar(_ field: String, _ value: String, contact: inout Person) {
        switch field {
        case "displayName": contact.displayName = value
        case "givenName": contact.givenName = value
        case "familyName": contact.familyName = value
        case "middleName": contact.middleName = value
        case "organization": contact.organization = value
        case "jobTitle": contact.jobTitle = value
        default: break
        }
    }

    static func importedValues(_ incoming: ImportedPerson, _ field: PersonListField) -> [String] {
        switch field {
        case .phones: incoming.phones
        case .emails: incoming.emails
        case .usernames: incoming.usernames
        case .tags: incoming.tags
        }
    }

    static func apply(_ draft: PersonDraft, to contact: inout Person) {
        contact.kind = draft.kind
        contact.displayName = trimmed(draft.displayName)
        contact.givenName = trimmed(draft.givenName)
        contact.familyName = trimmed(draft.familyName)
        contact.middleName = trimmed(draft.middleName)
        contact.organization = trimmed(draft.organization)
        contact.jobTitle = trimmed(draft.jobTitle)
        contact.phones = unique(draft.phones)
        contact.emails = unique(draft.emails)
        contact.usernames = unique(draft.usernames)
        contact.tags = unique(draft.tags)
    }

    static func validate(_ draft: PersonDraft) throws {
        guard !trimmed(draft.displayName).isEmpty else { throw StoreError.invalid("Укажите имя контакта.") }
    }

    static func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func observe(field: String, value: String, source: SourceStamp, contact: inout Person) {
        if let index = contact.observations.firstIndex(where: {
            $0.field == field && $0.value == value && $0.source.identity == source.identity && $0.status != .proposed
        }) {
            if source.fetchedAt > contact.observations[index].source.fetchedAt {
                contact.observations[index].source.fetchedAt = source.fetchedAt
            }
        } else {
            contact.observations.append(Observation(field: field, value: value, source: source))
        }
    }
    static func unique(_ values: [String]) -> [String] { union([], values.map(trimmed).filter { !$0.isEmpty }) }
    static func union<T: Equatable>(_ first: [T], _ second: [T]) -> [T] {
        var result = first
        for value in second where !result.contains(value) { result.append(value) }
        return result
    }
    private static func normalizedEmail(_ value: String) -> String { trimmed(value).lowercased() }
    private static func normalizedPhone(_ value: String) -> String { value.filter { $0.isASCII && $0.isNumber } }
}

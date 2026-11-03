import Foundation

/// Pure provenance rules shared by contact edits, imports and merges.
/// Manual fields suppress import writes; every observation is retained.
enum ContactReconciliation {
    static func contentWithoutFetchDates(_ contact: Contact) -> Contact {
        var copy = contact
        copy.revision = 0
        for index in copy.observations.indices { copy.observations[index].source.fetchedAt = Date(timeIntervalSince1970: 0) }
        for index in copy.notes.indices { copy.notes[index].source.fetchedAt = Date(timeIntervalSince1970: 0) }
        return copy
    }

    static func recordManualChanges(from before: ContactDraft?, contact: inout Contact) {
        let source = SourceStamp(identity: ServiceIdentity(service: "manual", accountID: "local", externalID: contact.id.uuidString))
        for (field, value, old) in [
            ("displayName", contact.displayName, before?.displayName),
            ("organization", contact.organization, before?.organization),
            ("jobTitle", contact.jobTitle, before?.jobTitle),
        ] {
            if old == nil || value != old { observe(field: field, value: value, source: source, contact: &contact) }
        }
        for (field, values, old) in [
            ("phones", contact.phones, before?.phones),
            ("emails", contact.emails, before?.emails),
            ("tags", contact.tags, before?.tags),
        ] {
            if old == nil || values != old {
                // Empty is an explicit manual clearance, retained in provenance.
                for value in values.isEmpty ? [""] : values { observe(field: field, value: value, source: source, contact: &contact) }
            }
        }
    }

    static func absorb(_ incoming: ImportedContact, source: SourceStamp, into contact: inout Contact) {
        let scalarFields: [(String, String?)] = [
            ("displayName", incoming.displayName), ("organization", incoming.organization),
            ("jobTitle", incoming.jobTitle),
        ]
        for (field, value) in scalarFields {
            guard let value else { continue }
            let cleaned = trimmed(value)
            let latest = contact.observations.filter { $0.field == field }.map(\.source.fetchedAt).max()
            observe(field: field, value: cleaned, source: source, contact: &contact)
            guard !contact.manualFields.contains(field), latest.map({ source.fetchedAt >= $0 }) ?? true else { continue }
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
            } else {
                contact.notes.append(ContactNote(text: text, source: source))
            }
        }
    }

    /// Unions both histories. A confirmed merge also confirms the survivor's
    /// scalar choice, so re-import cannot silently reverse it.
    static func merged(_ survivor: Contact, absorbing removed: Contact) -> Contact {
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
        merged.revision = max(survivor.revision, removed.revision) + 1
        merged.events.append(ContactEvent(kind: "merge", detail: "Объединено с \(removed.displayName)"))
        return merged
    }

    static func duplicateReasons(_ first: Contact, _ second: Contact) -> [String] {
        let emails = Set(first.emails.map(normalizedEmail).filter { !$0.isEmpty })
            .intersection(second.emails.map(normalizedEmail).filter { !$0.isEmpty })
        let phones = Set(first.phones.map(normalizedPhone).filter { !$0.isEmpty })
            .intersection(second.phones.map(normalizedPhone).filter { !$0.isEmpty })
        var reasons: [String] = []
        if !emails.isEmpty { reasons.append("Совпадает email") }
        if !phones.isEmpty { reasons.append("Совпадает телефон") }
        return reasons
    }

    static func apply(_ draft: ContactDraft, to contact: inout Contact) {
        contact.displayName = trimmed(draft.displayName)
        contact.organization = trimmed(draft.organization)
        contact.jobTitle = trimmed(draft.jobTitle)
        contact.phones = unique(draft.phones)
        contact.emails = unique(draft.emails)
        contact.tags = unique(draft.tags)
    }

    static func validate(_ draft: ContactDraft) throws {
        guard !trimmed(draft.displayName).isEmpty else { throw StoreError.invalid("Укажите имя контакта.") }
    }

    static func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func observe(field: String, value: String, source: SourceStamp, contact: inout Contact) {
        if let index = contact.observations.firstIndex(where: {
            $0.field == field && $0.value == value && $0.source.identity == source.identity
        }) {
            if source.fetchedAt > contact.observations[index].source.fetchedAt {
                contact.observations[index].source.fetchedAt = source.fetchedAt
            }
        } else {
            contact.observations.append(Observation(field: field, value: value, source: source))
        }
    }
    private static func unique(_ values: [String]) -> [String] { union([], values.map(trimmed).filter { !$0.isEmpty }) }
    private static func union<T: Equatable>(_ first: [T], _ second: [T]) -> [T] {
        var result = first
        for value in second where !result.contains(value) { result.append(value) }
        return result
    }
    private static func normalizedEmail(_ value: String) -> String { trimmed(value).lowercased() }
    private static func normalizedPhone(_ value: String) -> String { value.filter { $0.isASCII && $0.isNumber } }
}

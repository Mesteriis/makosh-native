import Foundation
import MakoshCore

public struct MergedPair: Equatable, Sendable {
    public var survivor: UUID
    public var removed: UUID
    public init(survivor: UUID, removed: UUID) {
        self.survivor = survivor
        self.removed = removed
    }
}

public struct CollectResult: Equatable, Sendable {
    public var created = 0
    public var updated = 0
    public var merged: [MergedPair] = []
    public var suggestedMemberships = 0
    public var hidden: [UUID] = []
    public var restored: [UUID] = []
    public init() {}
}

/// Applies what channels and books saw to the person store: link or create, count mail
/// evidence, one automatic merge per person, then organizations by company and domain.
public actor PersonCollector {
    private let persons: PersonStore
    private let store: PersonsStore
    private let now: @Sendable () -> Date

    public init(persons: PersonStore, store: PersonsStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.persons = persons
        self.store = store
        self.now = now
    }

    /// `addressBookSource`: observations from this book flag their persons as the user's address book.
    public func collect(
        _ observations: [PersonSourceObservation], spam: [MailEvidence] = [], addressBookSource: ImportSource? = nil
    ) async throws -> CollectResult {
        var result = CollectResult()
        let preferences = try await store.preferences()
        for observation in observations {
            let identity = ServiceIdentity(
                service: observation.source.service, accountID: observation.source.accountID, externalID: observation.person.externalID)
            let existed = try persons.personsOwning(identity).first
            // A known target (a card Makosh wrote) attaches the identity there; an unknown card finds or creates its own person.
            let target = try observation.personID.flatMap { try persons.person(id: $0) }?.id
            var id = try persons.linkImportedPerson(
                observation.person, source: observation.source, fetchedAt: observation.observedAt, contactID: existed == nil ? target : nil)
            if existed == nil { result.created += 1 } else { result.updated += 1 }
            if case .mail(let evidence) = observation.evidence {
                _ = try persons.recordMailEvidence(accountID: evidence.accountID, address: evidence.address, spam: false)
                if let person = try persons.person(id: id), person.hiddenAsSpam {
                    try persons.setHiddenAsSpam(id: id, false)
                    result.restored.append(id)
                }
            }
            if let addressBookSource, addressBookSource == observation.source, let person = try persons.person(id: id), person.isActive {
                try persons.setAddressBook(personID: id, true, origin: .sourceAccount(addressBookSource))
            }
            if let pair = try persons.autoMerge(personID: id) {
                result.merged.append(MergedPair(survivor: pair.survivor, removed: pair.removed))
                id = pair.survivor
            }
            result.suggestedMemberships += try suggestOrganizations(for: id, preferences: preferences)
        }
        for evidence in spam {
            let counts = try persons.recordMailEvidence(accountID: evidence.accountID, address: evidence.address, spam: true)
            let identity = ServiceIdentity(
                service: "mail", accountID: evidence.accountID, externalID: PersonMatching.normalizedEmail(evidence.address))
            // Hidden only when spam outweighs the clean letters and nothing but mail ever saw the person.
            guard let person = try persons.personsOwning(identity).first, person.isActive, counts.spam >= counts.clean,
                person.identities.allSatisfy({ $0.service == "mail" })
            else { continue }
            try persons.setHiddenAsSpam(id: person.id, true)
            result.hidden.append(person.id)
        }
        return result
    }

    private func suggestOrganizations(for personID: UUID, preferences: PersonsPreferences) throws -> Int {
        guard let person = try persons.person(id: personID), person.isActive, person.kind == .person else { return 0 }
        let domains = Set(person.emails.compactMap(OrganizationRules.domain(of:)))
        let counts = domains.isEmpty ? [:] : try persons.domainAddressCounts(domains: domains)
        let suggestions = OrganizationRules.suggestions(
            for: person, domainAddressCounts: counts, existing: try persons.organizations(), preferences: preferences)
        var added = 0
        for suggestion in suggestions {
            let organizationID = try suggestion.existingOrganizationID ?? persons.createOrganization(name: suggestion.organizationName)
            if try persons.suggestMembership(
                personID: personID, organizationID: organizationID, role: suggestion.role, origin: suggestion.origin) != nil
            {
                added += 1
            }
            // A domain organization gathers the other collected persons of that domain too.
            if case .emailDomain(let domain) = suggestion.origin {
                for other in try persons.persons()
                where other.id != personID && other.kind == .person && other.emails.contains { OrganizationRules.domain(of: $0) == domain }
                {
                    if try persons.suggestMembership(
                        personID: other.id, organizationID: organizationID, role: "", origin: suggestion.origin)
                        != nil
                    {
                        added += 1
                    }
                }
            }
        }
        return added
    }
}

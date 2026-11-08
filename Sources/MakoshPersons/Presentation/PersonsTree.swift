import Foundation
import MakoshCore

package enum PersonsFilter: String, Codable, Sendable, CaseIterable {
    case all, addressBook, deleted, hidden, notSynced, suggested

    package var title: String {
        switch self {
        case .all: "Все"
        case .addressBook: "Адресная книга"
        case .deleted: "Удалённые"
        case .hidden: "Скрытые"
        case .notSynced: "Не ушли наружу"
        case .suggested: "Предложено Makosh"
        }
    }
}

/// One row of the section's list: an organization that opens into its people, a person,
/// or the «Без организации» section at the bottom.
package struct PersonsTreeNode: Identifiable, Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case organization(UUID, count: Int)
        case person(PersonSummary)
        case section(String)
    }
    package let id: String
    package let kind: Kind
    package var children: [PersonsTreeNode]
    /// A person whose membership here is only suggested by Makosh.
    package var suggested = false
    /// A flagged person that cannot reach at least one book.
    package var blocked = false

    package var title: String {
        switch kind {
        case .organization: ""
        case .person(let summary): summary.displayName
        case .section(let title): title
        }
    }

    package var personID: UUID? {
        if case .person(let summary) = kind { return summary.id }
        return nil
    }
}

package enum PersonsTree {
    /// Organizations by name, each with its members by name; people in several organizations
    /// appear under each; the rest go to «Без организации». A filter narrows the people; an
    /// organization stays only while it has someone to show.
    package static func build(
        summaries: [PersonSummary], organizations: [PersonSummary], memberships: [PersonMembership], expanded: Set<UUID>,
        filter: PersonsFilter, blocked: Set<UUID>, suggestedPersonIDs: Set<UUID>, search: String = ""
    ) -> [PersonsTreeNode] {
        let people = summaries.filter { $0.kind == .person && passes($0, filter: filter, blocked: blocked, suggested: suggestedPersonIDs) }
        let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        let active = memberships.filter { $0.state != .removed }
        var placed = Set<UUID>()
        var nodes: [PersonsTreeNode] = []
        for organization in organizations.filter({ $0.kind == .organization }).sorted(by: byName) {
            let members = active.filter { $0.organizationID == organization.id }
            let shown = members.compactMap { membership in byID[membership.personID].map { ($0, membership.state == .suggested) } }
                .sorted { byName($0.0, $1.0) }
            placed.formUnion(shown.map(\.0.id))
            // A narrowed list shows an organization only with someone inside it, or when its own name matches.
            let narrowed = filter != .all || !search.isEmpty
            if narrowed && shown.isEmpty && !organization.displayName.localizedCaseInsensitiveContains(search) { continue }
            if narrowed && shown.isEmpty && search.isEmpty { continue }
            let children =
                expanded.contains(organization.id)
                ? shown.map { summary, suggested in
                    PersonsTreeNode(
                        id: organization.id.uuidString + "/" + summary.id.uuidString, kind: .person(summary), children: [],
                        suggested: suggested, blocked: blocked.contains(summary.id))
                } : []
            nodes.append(
                PersonsTreeNode(
                    id: organization.id.uuidString, kind: .organization(organization.id, count: shown.count), children: children))
        }
        let rest = people.filter { !placed.contains($0.id) }.sorted(by: byName)
        if !rest.isEmpty {
            nodes.append(
                PersonsTreeNode(
                    id: "rest", kind: .section("Без организации"),
                    children: rest.map {
                        PersonsTreeNode(id: "rest/" + $0.id.uuidString, kind: .person($0), children: [], blocked: blocked.contains($0.id))
                    }))
        }
        return nodes
    }

    static func passes(_ summary: PersonSummary, filter: PersonsFilter, blocked: Set<UUID>, suggested: Set<UUID>) -> Bool {
        switch filter {
        case .all, .deleted, .hidden: true
        case .addressBook: summary.addressBook
        case .notSynced: blocked.contains(summary.id)
        case .suggested: suggested.contains(summary.id)
        }
    }

    static func byName(_ a: PersonSummary, _ b: PersonSummary) -> Bool {
        let comparison = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
        return comparison == .orderedSame ? a.id.uuidString < b.id.uuidString : comparison == .orderedAscending
    }
}

import Foundation
import MakoshCore

/// People API v1 JSON ↔ cards. Only the fields Makosh exchanges.
enum GoogleContactsMapping {
    static let personFields = "names,emailAddresses,phoneNumbers,organizations,clientData,metadata"
    static let updateFields = "names,emailAddresses,phoneNumbers,organizations,clientData"
    static let markerKey = "makosh-person"
    static let kindKey = "makosh-kind"

    struct Name: Codable {
        var displayName: String?
        var givenName: String?
        var familyName: String?
        var middleName: String?
        var unstructuredName: String?
    }
    struct Value: Codable { var value: String? }
    struct Organization: Codable {
        var name: String?
        var title: String?
        var type: String?
    }
    struct ClientData: Codable {
        var key: String?
        var value: String?
    }
    struct Metadata: Codable { var deleted: Bool? }
    struct GooglePerson: Codable {
        var resourceName: String?
        var etag: String?
        var names: [Name]?
        var emailAddresses: [Value]?
        var phoneNumbers: [Value]?
        var organizations: [Organization]?
        var clientData: [ClientData]?
        var metadata: Metadata?
    }
    struct Page: Codable {
        var connections: [GooglePerson]?
        var nextPageToken: String?
        var nextSyncToken: String?
    }

    /// A connection as a card; nil for a deleted or nameless entry (the caller lists deletions).
    static func remoteCard(_ person: GooglePerson) -> RemoteCard? {
        guard let resourceName = person.resourceName, person.metadata?.deleted != true else { return nil }
        let name = person.names?.first
        let display =
            name?.displayName ?? name?.unstructuredName ?? [name?.givenName, name?.familyName].compactMap { $0 }.joined(separator: " ")
        guard !display.isEmpty else { return nil }
        let client = Dictionary((person.clientData ?? []).compactMap { data in data.key.map { ($0, data.value ?? "") } }) { first, _ in
            first
        }
        let kind: PersonKind = client[kindKey] == "organization" ? .organization : .person
        let organization = person.organizations?.first
        let imported = ImportedPerson(
            externalID: resourceName, displayName: display, kind: kind == .organization ? .organization : nil, givenName: name?.givenName,
            familyName: name?.familyName, middleName: name?.middleName, organization: organization?.name, jobTitle: organization?.title,
            phones: (person.phoneNumbers ?? []).compactMap(\.value), emails: (person.emailAddresses ?? []).compactMap(\.value))
        return RemoteCard(
            externalID: resourceName, etag: person.etag, makoshID: client[markerKey].flatMap(UUID.init(uuidString:)), imported: imported,
            kind: kind)
    }

    static func body(for card: PersonCard, etag: String?) -> GooglePerson {
        var person = GooglePerson()
        person.etag = etag
        if card.kind == .organization {
            person.names = [Name(displayName: nil, givenName: nil, familyName: nil, middleName: nil, unstructuredName: card.displayName)]
            person.organizations = [Organization(name: card.displayName, title: nil, type: "company")]
        } else {
            person.names = [
                Name(
                    displayName: nil, givenName: card.givenName.isEmpty ? card.displayName : card.givenName,
                    familyName: card.familyName.isEmpty ? nil : card.familyName,
                    middleName: card.middleName.isEmpty ? nil : card.middleName,
                    unstructuredName: nil)
            ]
            if !card.organization.isEmpty || !card.jobTitle.isEmpty {
                person.organizations = [
                    Organization(
                        name: card.organization.isEmpty ? nil : card.organization, title: card.jobTitle.isEmpty ? nil : card.jobTitle,
                        type: nil)
                ]
            } else {
                person.organizations = []
            }
        }
        person.emailAddresses = card.emails.map { Value(value: $0) }
        person.phoneNumbers = card.phones.map { Value(value: $0) }
        person.clientData = [
            ClientData(key: markerKey, value: card.makoshID.uuidString), ClientData(key: kindKey, value: card.kind.rawValue),
        ]
        return person
    }
}

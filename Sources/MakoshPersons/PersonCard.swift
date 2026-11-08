import CryptoKit
import Foundation
import MakoshCore

/// What leaves Makosh for an external book: a flat card without notes, tags,
/// former values or organization nesting.
public struct PersonCard: Codable, Equatable, Sendable {
    public var makoshID: UUID
    public var kind: PersonKind
    public var displayName: String
    public var givenName: String
    public var familyName: String
    public var middleName: String
    public var phones: [String]
    public var emails: [String]
    public var organization: String
    public var jobTitle: String

    public init(
        makoshID: UUID, kind: PersonKind, displayName: String, givenName: String, familyName: String, middleName: String,
        phones: [String], emails: [String], organization: String, jobTitle: String
    ) {
        self.makoshID = makoshID
        self.kind = kind
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.middleName = middleName
        self.phones = phones
        self.emails = emails
        self.organization = organization
        self.jobTitle = jobTitle
    }

    /// SHA-256 of the canonical card: trimmed strings, sorted lists, fixed field order.
    public var fingerprint: String {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let parts: [String] = [
            makoshID.uuidString.lowercased(), kind.rawValue, clean(displayName), clean(givenName), clean(familyName), clean(middleName),
            phones.map(clean).sorted().joined(separator: ","), emails.map(clean).sorted().joined(separator: ","), clean(organization),
            clean(jobTitle),
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum PersonCardBuilder {
    /// The organization text is the person's own field, else the first confirmed membership;
    /// the title is that membership's role when it has one.
    public static func card(for person: Person, memberships: [PersonMembership], organizations: [UUID: Person]) -> PersonCard {
        let confirmed = memberships.filter { $0.personID == person.id && $0.state == .confirmed }.sorted { $0.createdAt < $1.createdAt }
        let membership = confirmed.first { organizations[$0.organizationID] != nil }
        let organization =
            person.organization.isEmpty ? (membership.flatMap { organizations[$0.organizationID]?.displayName } ?? "") : person.organization
        let title = membership.map(\.role).flatMap { $0.isEmpty ? nil : $0 } ?? person.jobTitle
        let parts = person.kind == .person ? person.nameParts : (given: "", family: "")
        return PersonCard(
            makoshID: person.id, kind: person.kind, displayName: person.displayName, givenName: parts.given, familyName: parts.family,
            middleName: person.kind == .person ? person.middleName : "", phones: person.phones, emails: person.emails,
            organization: organization, jobTitle: title)
    }
}

/// A card as a book returned it, before it becomes an observation.
public struct RemoteCard: Equatable, Sendable {
    public var externalID: String
    public var etag: String?
    public var makoshID: UUID?
    public var imported: ImportedPerson
    public var kind: PersonKind
    public init(externalID: String, etag: String?, makoshID: UUID?, imported: ImportedPerson, kind: PersonKind) {
        self.externalID = externalID
        self.etag = etag
        self.makoshID = makoshID
        self.imported = imported
        self.kind = kind
    }
}

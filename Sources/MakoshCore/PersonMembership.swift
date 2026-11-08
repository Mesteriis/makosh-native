import Foundation

/// How a person came to be inside an organization.
public enum MembershipOrigin: Codable, Equatable, Sendable {
    case manual
    case companyField(ImportSource)
    case emailDomain(String)
    case ai
}

public enum MembershipState: String, Codable, Sendable { case suggested, confirmed, removed }

/// One person inside one organization. Automatic memberships start as suggestions;
/// a removed suggestion is remembered so the same reason never proposes it again.
public struct PersonMembership: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var organizationID: UUID
    public var personID: UUID
    public var role: String
    public var origin: MembershipOrigin
    public var state: MembershipState
    public var createdAt: Date
    public var updatedAt: Date
    public init(
        id: UUID = UUID(), organizationID: UUID, personID: UUID, role: String, origin: MembershipOrigin, state: MembershipState,
        createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.organizationID = organizationID
        self.personID = personID
        self.role = role
        self.origin = origin
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// The only moves the store accepts.
    static func allows(_ from: MembershipState, _ to: MembershipState) -> Bool {
        switch (from, to) {
        case (.suggested, .confirmed), (.suggested, .removed), (.confirmed, .removed), (.removed, .confirmed): true
        default: false
        }
    }
}

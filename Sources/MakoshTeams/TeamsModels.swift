import Foundation

/// Identity strings remain wire-exact; Swift's canonical Unicode equality is unsuitable for resource IDs.
func teamsIdentityKey(_ components: [String]) -> Data {
    var result = Data()
    for component in components {
        let bytes = Data(component.utf8)
        var count = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
        result.append(bytes)
    }
    return result
}

public enum TeamsFailure: Error, Codable, Equatable, Sendable {
    case storage, keyUnavailable, principalChanged, operationBusy, uncertainSubmission
    case historicalFileUnavailable, incompleteRoster, rosterChanged, incompleteGrant
    case invalidResource, invalidContinuation, invalidResponse, bodyTooLarge, redirectRejected
    case invalidConfiguration, invalidAuthorization, authorizationExpired, authorizationDenied, signInRequired, invalidToken, credentialStorage
    case unauthorized, forbidden, throttled(retryAfter: TimeInterval), server(status: Int), transport
}

public struct TeamsPrincipal: Codable, Hashable, Sendable {
    public let tenantID: String
    public let userID: String
    public let displayName: String
    public init(tenantID: String, userID: String, displayName: String) {
        self.tenantID = tenantID; self.userID = userID; self.displayName = displayName
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
    private var key: Data { teamsIdentityKey([tenantID, userID]) }
}

public struct TeamsAccountContext: Codable, Hashable, Sendable {
    public let accountID: UUID
    public let principal: TeamsPrincipal
    public init(accountID: UUID, principal: TeamsPrincipal) { self.accountID = accountID; self.principal = principal }
}

public enum TeamsResource: Codable, Hashable, Sendable {
    case chat(String)
    case channel(teamID: String, channelID: String)
    case thread(teamID: String, channelID: String, rootID: String)
    var components: [String] {
        switch self {
        case let .chat(id): ["chat", id]
        case let .channel(teamID, channelID): ["channel", teamID, channelID]
        case let .thread(teamID, channelID, rootID): ["thread", teamID, channelID, rootID]
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { teamsIdentityKey(lhs.components) == teamsIdentityKey(rhs.components) }
    public func hash(into hasher: inout Hasher) { hasher.combine(teamsIdentityKey(components)) }
}

public struct TeamsScope: Codable, Hashable, Sendable {
    public let accountID: UUID
    public let tenantID: String
    public let resource: TeamsResource
    public init(accountID: UUID, tenantID: String, resource: TeamsResource) {
        self.accountID = accountID; self.tenantID = tenantID; self.resource = resource
    }
    public var storageKey: Data { teamsIdentityKey([accountID.uuidString, tenantID] + resource.components) }
    public var policyScope: Self {
        guard case let .thread(team, channel, _) = resource else { return self }
        return Self(accountID: accountID, tenantID: tenantID, resource: .channel(teamID: team, channelID: channel))
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storageKey == rhs.storageKey }
    public func hash(into hasher: inout Hasher) { hasher.combine(storageKey) }
}

public struct TeamsCollection: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case chats, joinedTeams, channels(String), messages(TeamsResource), replies(TeamsResource), members(TeamsResource), driveFolders(String?)
        var components: [String] {
            switch self {
            case .chats: ["me", "chats"]
            case .joinedTeams: ["me", "joinedTeams"]
            case let .driveFolders(parent): ["me", "drive"] + (parent.map { ["items", $0, "children"] } ?? ["root", "children"])
            case let .channels(team): ["teams", team, "channels"]
            case let .messages(.chat(id)): ["chats", id, "messages"]
            case let .messages(.channel(team, channel)): ["teams", team, "channels", channel, "messages"]
            case let .messages(.thread(team, channel, root)), let .replies(.thread(team, channel, root)):
                ["teams", team, "channels", channel, "messages", root, "replies"]
            case let .members(.chat(id)): ["chats", id, "members"]
            case let .members(.channel(team, channel)), let .members(.thread(team, channel, _)): ["teams", team, "channels", channel, "allMembers"]
            default: []
            }
        }
        public static func == (lhs: Self, rhs: Self) -> Bool { teamsIdentityKey(lhs.components) == teamsIdentityKey(rhs.components) }
        public func hash(into hasher: inout Hasher) { hasher.combine(teamsIdentityKey(components)) }
    }
    public let context: TeamsAccountContext
    public let kind: Kind
    public init(context: TeamsAccountContext, kind: Kind) { self.context = context; self.kind = kind }
}

public struct TeamsContinuation: Codable, Equatable, Sendable {
    public let owner: TeamsCollection
    public let url: URL
    let visited: Set<Data>
    public init(owner: TeamsCollection, url: URL) { self.init(owner: owner, url: url, visited: []) }
    init(owner: TeamsCollection, url: URL, visited: Set<Data>) { self.owner = owner; self.url = url; self.visited = visited }
}

public struct TeamsPage<Item: Codable & Sendable>: Sendable {
    public let values: [Item]
    public let next: TeamsContinuation?
    public let continuationFailure: TeamsFailure?
}

public struct TeamsGraphUser: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let mail: String?
}

public struct TeamsAccount: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let clientID: String
    public let authority: String
    public let verifiedPrincipal: TeamsPrincipal?
    public let readOnly: Bool
    public init(id: UUID, name: String, clientID: String, authority: String, verifiedPrincipal: TeamsPrincipal?, readOnly: Bool) {
        self.id = id; self.name = name; self.clientID = clientID; self.authority = authority
        self.verifiedPrincipal = verifiedPrincipal; self.readOnly = readOnly
    }
}

public struct TeamsTeam: Codable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public init(id: String, displayName: String) { self.id = id; self.displayName = displayName }
}

public struct TeamsChannel: Codable, Identifiable, Sendable {
    public let id: String
    public let teamID: String
    public let displayName: String
    public init(id: String, teamID: String, displayName: String) { self.id = id; self.teamID = teamID; self.displayName = displayName }
}

public enum TeamsConversationKind: String, Codable, Sendable { case oneOnOne, group, meeting, channel, unknown }

public struct TeamsConversation: Codable, Identifiable, Sendable {
    public let scope: TeamsScope
    public let displayName: String
    public let kind: TeamsConversationKind
    /// Expanded display hints only. File grants require a separately paginated and rechecked roster.
    public let members: [TeamsPerson]?
    public var id: Data { scope.storageKey }
    public init(scope: TeamsScope, displayName: String, kind: TeamsConversationKind, members: [TeamsPerson]? = nil) {
        self.scope = scope; self.displayName = displayName; self.kind = kind; self.members = members
    }
}

public struct TeamsPerson: Codable, Sendable {
    public let userID: String
    public let tenantID: String
    public let displayName: String
    public let email: String?
    public init(userID: String, tenantID: String, displayName: String, email: String?) {
        self.userID = userID; self.tenantID = tenantID; self.displayName = displayName; self.email = email
    }
}

/// Graph metadata only. File/hosted-content payloads never enter a database DTO.
public struct TeamsAttachment: Codable, Sendable {
    public let id: String
    public let name: String?
    public let contentType: String?
    public let contentURL: URL?
    enum CodingKeys: String, CodingKey { case id, name, contentType; case contentURL = "contentUrl" }
    public init(id: String, name: String?, contentType: String?, contentURL: URL?) {
        self.id = id; self.name = name; self.contentType = contentType; self.contentURL = contentURL
    }
}

public struct TeamsMessage: Codable, Sendable {
    public let id: String
    public let scope: TeamsScope
    public let body: String
    public let contentType: String
    public let author: TeamsPerson?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let deletedAt: Date?
    public let attachments: [TeamsAttachment]
    public let replyTo: String?
    public let metadata: [String: String]
    public init(id: String, scope: TeamsScope, body: String, contentType: String, author: TeamsPerson?,
                createdAt: Date?, modifiedAt: Date?, deletedAt: Date?, attachments: [TeamsAttachment],
                replyTo: String?, metadata: [String: String] = [:]) {
        self.id = id; self.scope = scope; self.body = body; self.contentType = contentType; self.author = author
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.deletedAt = deletedAt
        self.attachments = attachments; self.replyTo = replyTo; self.metadata = metadata
    }
}

import Foundation
import MakoshCore
import MakoshJira

/// One Jira site the user signed into; the token lives in the vault, not here.
public struct JiraConnection: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var origin: URL
    public var email: String
    public var accountID: String?
    public var pollInterval: TimeInterval
    public var mentions: Bool
    public var suggestWorklog: Bool
    public var lastSyncAt: Date?
    public var lastFailure: String?
    public var mentionsUnavailable: Bool

    public init(
        id: UUID = UUID(), name: String, origin: URL, email: String, accountID: String? = nil, pollInterval: TimeInterval = 300,
        mentions: Bool = true,
        suggestWorklog: Bool = true, lastSyncAt: Date? = nil, lastFailure: String? = nil, mentionsUnavailable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.email = email
        self.accountID = accountID
        self.pollInterval = pollInterval
        self.mentions = mentions
        self.suggestWorklog = suggestWorklog
        self.lastSyncAt = lastSyncAt
        self.lastFailure = lastFailure
        self.mentionsUnavailable = mentionsUnavailable
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        origin = try values.decode(URL.self, forKey: .origin)
        email = try values.decode(String.self, forKey: .email)
        accountID = try values.decodeIfPresent(String.self, forKey: .accountID)
        pollInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? 300
        mentions = try values.decodeIfPresent(Bool.self, forKey: .mentions) ?? true
        suggestWorklog = try values.decodeIfPresent(Bool.self, forKey: .suggestWorklog) ?? true
        lastSyncAt = try values.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastFailure = try values.decodeIfPresent(String.self, forKey: .lastFailure)
        mentionsUnavailable = try values.decodeIfPresent(Bool.self, forKey: .mentionsUnavailable) ?? false
    }

    /// HTTPS origin without a path or query, a name, an email with one `@`.
    public func validated() throws -> JiraConnection {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 80 else { throw TasksFailure.invalidConnection("название до 80 символов") }
        guard origin.scheme?.lowercased() == "https", let host = origin.host, !host.isEmpty, origin.user == nil, origin.query == nil,
            origin.fragment == nil, origin.path.isEmpty || origin.path == "/"
        else { throw TasksFailure.invalidConnection("нужен HTTPS-адрес сайта без пути и учётных данных") }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, email.utf8.count <= 254,
            email.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw TasksFailure.invalidConnection("почта вида name@domain") }
        guard pollInterval >= 60, pollInterval <= 86_400 else { throw TasksFailure.invalidConnection("период опроса от 1 минуты до суток") }
        var value = self
        value.name = trimmedName
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = ""
        value.origin = components.url ?? origin
        return value
    }

    public func credential(token: String) -> JiraCredential { JiraCredential(origin: origin, email: email, apiToken: token) }
}

extension TaskStore {
    public func connections() throws -> [JiraConnection] {
        try query("SELECT data FROM \(t("tasks_jira_connections")) ORDER BY data->>'name'").map { try decode(JiraConnection.self, $0[0]) }
    }

    public func saveConnection(_ connection: JiraConnection) throws {
        try execute(
            "INSERT INTO \(t("tasks_jira_connections"))(id, data) VALUES($1, $2::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data",
            [connection.id.uuidString, try encode(connection)])
    }

    /// Removes the row and turns the connection's tasks into `none`; identities and history stay.
    public func removeConnection(id: UUID) throws {
        try transaction {
            for (taskID, source) in try self.sources(connectionID: id) where source.membership != .none {
                try self.setMembership(taskID: taskID, .none)
            }
            try self.execute("DELETE FROM \(self.t("tasks_jira_connections")) WHERE id = $1", [id.uuidString])
        }
    }
}

/// Connections in the store, tokens in the vault; removal drops the token first.
public actor JiraConnectionRegistry {
    private let store: TaskStore
    private let vault: JiraTokenVault

    public init(store: TaskStore, vault: JiraTokenVault) {
        self.store = store
        self.vault = vault
    }

    public func connections() async throws -> [JiraConnection] { try await store.connections() }

    public func token(connectionID: UUID) async throws -> String? { try await vault.load(connectionID: connectionID) }

    /// Saves the connection; a nil token keeps the stored one.
    public func save(_ connection: JiraConnection, token: String?) async throws {
        let value = try connection.validated()
        if let token { try await vault.save(token, connectionID: value.id) }
        try await store.saveConnection(value)
    }

    public func remove(_ id: UUID) async throws {
        try await vault.remove(connectionID: id)
        try await store.removeConnection(id: id)
    }
}

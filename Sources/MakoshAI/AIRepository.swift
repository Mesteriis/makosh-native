import Foundation
import MakoshCore

/// Encrypted storage for connections, role assignments and conversations.
/// Unlike the message archive, AI conversations are the user's own content
/// and may be deleted.
public actor AIRepository {
    private enum Kind: String { case connection, role, conversation, message, settings }
    private let keyProvider: @Sendable (UUID, Bool) throws -> Data
    private var database: AIPostgres?

    public init(keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open) {
        self.keyProvider = keyProvider
    }

    public func open(configuration: ContactWorkspaceConfiguration) throws {
        if let database {
            guard database.configuration.schema == configuration.schema,
                database.configuration.connectionString == configuration.connectionString
            else { throw AIFailure.invalidConfiguration }
            return
        }
        let db = try AIPostgres(configuration: configuration)
        try db.open(keyProvider: keyProvider)
        database = db
    }

    public func close() {
        database?.close()
        database = nil
    }

    public func connections() throws -> [AIConnection] {
        try records(AIConnection.self, kind: .connection).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func save(_ connection: AIConnection) throws {
        try put(connection.validated(), kind: .connection, key: connection.id.uuidString)
    }
    public func removeConnection(_ id: UUID) throws {
        let db = try db()
        try db.transaction {
            try delete(kind: .connection, key: id.uuidString)
            for assignment in try roles() where assignment.connectionID == id {
                try delete(kind: .role, key: assignment.role.rawValue)
            }
        }
    }

    public func roles() throws -> [AIRoleAssignment] {
        try records(AIRoleAssignment.self, kind: .role).sorted {
            AIRole.allCases.firstIndex(of: $0.role)! < AIRole.allCases.firstIndex(of: $1.role)!
        }
    }
    public func assign(_ assignment: AIRoleAssignment?, role: AIRole) throws {
        guard let assignment else { return try delete(kind: .role, key: role.rawValue) }
        guard assignment.role == role, !assignment.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            try connections().contains(where: { $0.id == assignment.connectionID })
        else { throw AIFailure.invalidConfiguration }
        try put(assignment, kind: .role, key: role.rawValue)
    }

    public func conversations() throws -> [AIConversation] {
        try records(AIConversation.self, kind: .conversation).sorted { $0.updatedAt > $1.updatedAt }
    }
    public func save(_ conversation: AIConversation) throws { try put(conversation, kind: .conversation, key: conversation.id.uuidString) }

    public func messages(conversationID: UUID) throws -> [AIMessage] {
        try records(AIMessage.self, kind: .message, owner: owner(conversationID))
    }
    public func save(_ message: AIMessage) throws {
        try put(message, kind: .message, key: message.id.uuidString, owner: owner(message.conversationID))
    }

    /// Returns the images whose stored bytes the caller must delete next.
    public func deleteConversation(_ id: UUID) throws -> [AIImageReference] {
        let db = try db()
        return try db.transaction {
            let images = try messages(conversationID: id).flatMap { $0.versions.compactMap(\.image) }
            try db.query("DELETE FROM \(db.prefix)ai_records WHERE kind=$1 AND owner=$2", [Kind.message.rawValue, try owner(id)])
            try delete(kind: .conversation, key: id.uuidString)
            return images
        }
    }

    /// Internal JSON settings such as the indexer's cursors.
    func setting<T: Decodable>(_ type: T.Type, key: String) throws -> T? { try record(type, kind: .settings, key: key) }
    func setSetting<T: Encodable>(_ value: T, key: String) throws { try put(value, kind: .settings, key: key) }
    public func imagesSavedToS3() throws -> Bool { try record(Bool.self, kind: .settings, key: "imagesSavedToS3") ?? true }
    public func setImagesSavedToS3(_ value: Bool) throws { try put(value, kind: .settings, key: "imagesSavedToS3") }

    private func db() throws -> AIPostgres {
        guard let database else { throw AIFailure.storage }
        return database
    }
    private func owner(_ conversationID: UUID) throws -> String { try db().token(["conversation", conversationID.uuidString]) }
    private func aad(_ token: String, _ kind: Kind) -> String { "record:\(kind.rawValue):\(token)" }

    private func put<T: Encodable>(_ value: T, kind: Kind, key: String, owner: String = "") throws {
        let db = try db(), token = try db.token([kind.rawValue, key])
        try db.query(
            "INSERT INTO \(db.prefix)ai_records(token,kind,owner,ciphertext) VALUES($1,$2,$3,$4) ON CONFLICT(token) DO UPDATE SET owner=EXCLUDED.owner,ciphertext=EXCLUDED.ciphertext",
            [token, kind.rawValue, owner, try db.seal(value, token: aad(token, kind))])
    }
    private func delete(kind: Kind, key: String) throws {
        let db = try db()
        try db.query("DELETE FROM \(db.prefix)ai_records WHERE token=$1", [try db.token([kind.rawValue, key])])
    }
    private func record<T: Decodable>(_ type: T.Type, kind: Kind, key: String) throws -> T? {
        let db = try db(), token = try db.token([kind.rawValue, key])
        guard
            let row = try db.query("SELECT ciphertext FROM \(db.prefix)ai_records WHERE token=$1 AND kind=$2", [token, kind.rawValue]).first
        else { return nil }
        return try db.decode(row[0], token: aad(token, kind))
    }
    private func records<T: Decodable>(_ type: T.Type, kind: Kind, owner: String? = nil) throws -> [T] {
        let db = try db()
        var sql = "SELECT token,ciphertext FROM \(db.prefix)ai_records WHERE kind=$1"
        var parameters = [kind.rawValue]
        if let owner {
            parameters.append(owner)
            sql += " AND owner=$2"
        }
        return try db.query(sql + " ORDER BY sequence", parameters).map { try db.decode($0[1], token: aad($0[0], kind)) }
    }
}

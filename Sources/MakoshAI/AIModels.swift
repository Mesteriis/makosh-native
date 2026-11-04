import Foundation

public enum AIRole: String, Codable, CaseIterable, Sendable {
    case chat, embeddings, images, transcription, speech
}

/// An OpenAI-compatible endpoint. The token is never part of this value; it
/// lives in the Keychain under the connection identifier.
public struct AIConnection: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: URL
    public var organization: String?
    public var project: String?
    public init(id: UUID = UUID(), name: String, baseURL: URL, organization: String? = nil, project: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.organization = organization
        self.project = project
    }
    /// HTTPS anywhere; plain HTTP only for loopback servers such as Ollama or LM Studio.
    public func validated() throws -> AIConnection {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 80,
            let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil, components.query == nil, components.fragment == nil
        else { throw AIFailure.invalidConnection }
        switch scheme {
        case "https": break
        case "http" where ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()): break
        default: throw AIFailure.invalidConnection
        }
        result.organization = Self.optional(organization)
        result.project = Self.optional(project)
        return result
    }
    private static func optional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public struct AIRoleAssignment: Codable, Equatable, Sendable {
    public let role: AIRole
    public let connectionID: UUID
    public let model: String
    public init(role: AIRole, connectionID: UUID, model: String) {
        self.role = role
        self.connectionID = connectionID
        self.model = model
    }
}

public struct AIConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    /// Whether questions in this conversation search permitted Makosh data.
    public var searchMyData: Bool
    public init(id: UUID = UUID(), title: String, createdAt: Date, updatedAt: Date, searchMyData: Bool = true) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.searchMyData = searchMyData
    }
    private enum CodingKeys: String, CodingKey { case id, title, createdAt, updatedAt, searchMyData }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        searchMyData = try c.decodeIfPresent(Bool.self, forKey: .searchMyData) ?? true
    }
}

/// `system` appears only in turns sent to the provider (retrieved context), never in stored messages.
public enum AIMessageAuthor: String, Codable, Sendable { case user, assistant, system }

public enum AIMessageState: String, Codable, Sendable { case complete, streaming, interrupted, failed }

/// An encrypted image envelope; `byteCount`/`sha256` describe the stored
/// envelope, `plaintextByteCount` the decrypted PNG. `key` is random per image
/// and lives only inside the encrypted message record: S3 denies deletion, so
/// deleting the record is what makes an S3 copy unreadable.
public struct AIImageReference: Codable, Equatable, Sendable {
    public let objectID: UUID
    public let byteCount: Int64
    public let sha256: String
    public let plaintextByteCount: Int64
    public let key: Data
    public let inS3: Bool
    public init(objectID: UUID, byteCount: Int64, sha256: String, plaintextByteCount: Int64, key: Data, inS3: Bool) {
        self.objectID = objectID
        self.byteCount = byteCount
        self.sha256 = sha256
        self.plaintextByteCount = plaintextByteCount
        self.key = key
        self.inS3 = inS3
    }
}

public struct AIMessageVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var state: AIMessageState
    public let model: String?
    public let createdAt: Date
    public var image: AIImageReference?
    /// Makosh messages and letters the answer was given from.
    public var sources: [AISourceReference]
    public init(
        id: UUID = UUID(), text: String, state: AIMessageState, model: String?, createdAt: Date, image: AIImageReference? = nil,
        sources: [AISourceReference] = []
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.model = model
        self.createdAt = createdAt
        self.image = image
        self.sources = sources
    }
    private enum CodingKeys: String, CodingKey { case id, text, state, model, createdAt, image, sources }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        state = try c.decode(AIMessageState.self, forKey: .state)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        image = try c.decodeIfPresent(AIImageReference.self, forKey: .image)
        sources = try c.decodeIfPresent([AISourceReference].self, forKey: .sources) ?? []
    }
}

public struct AIMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    /// The previous message on this branch and the version of it this
    /// message answers or follows; an edit adds a version, so the old branch
    /// stays reachable by selecting the old version.
    public let parentID: UUID?
    public let parentVersionID: UUID?
    public let author: AIMessageAuthor
    public var versions: [AIMessageVersion]
    public var selectedVersion: Int
    public init(
        id: UUID = UUID(), conversationID: UUID, parentID: UUID?, parentVersionID: UUID? = nil, author: AIMessageAuthor,
        versions: [AIMessageVersion], selectedVersion: Int = 0
    ) {
        self.id = id
        self.conversationID = conversationID
        self.parentID = parentID
        self.parentVersionID = parentVersionID
        self.author = author
        self.versions = versions
        self.selectedVersion = selectedVersion
    }
    public var current: AIMessageVersion? { versions.indices.contains(selectedVersion) ? versions[selectedVersion] : versions.last }

    /// The branch selected by each message's current version, from the root.
    public static func path(_ messages: [AIMessage]) -> [AIMessage] {
        var result: [AIMessage] = []
        var next = messages.first { $0.parentID == nil }
        while let message = next, !result.contains(where: { $0.id == message.id }) {
            result.append(message)
            let version = message.current?.id
            next = messages.last { $0.parentID == message.id && $0.parentVersionID == version }
        }
        return result
    }
}

public enum AIFailure: Error, Equatable, Sendable {
    case invalidConnection, invalidConfiguration, storage, keyUnavailable, roleUnassigned(AIRole)
    case unauthorized, rateLimited, server(status: Int), network, malformedResponse, cancelled, busy
    case vectorUnavailable, dimensionsTooLarge
}

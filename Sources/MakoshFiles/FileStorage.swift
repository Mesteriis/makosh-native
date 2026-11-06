import Foundation
import MakoshCore
import Security

/// A Paperless-ngx server. The token is never part of this value; it lives in
/// the Keychain under the connection identifier.
public struct PaperlessConnection: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: URL
    public var defaultDocumentType: Int?
    public var defaultTags: [Int]

    public init(id: UUID = UUID(), name: String, baseURL: URL, defaultDocumentType: Int? = nil, defaultTags: [Int] = []) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.defaultDocumentType = defaultDocumentType
        self.defaultTags = defaultTags
    }

    /// HTTPS anywhere; plain HTTP only for loopback servers. A trailing slash is dropped.
    public func validated() throws -> PaperlessConnection {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 80,
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil, components.query == nil, components.fragment == nil
        else { throw FilesFailure.invalidConnection }
        switch scheme {
        case "https": break
        case "http" where ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()): break
        default: throw FilesFailure.invalidConnection
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw FilesFailure.invalidConnection }
        result.baseURL = url
        return result
    }
}

/// Every kind of external storage the Files section can list and send to.
public enum FileStorageConnection: Codable, Equatable, Identifiable, Sendable {
    case paperless(PaperlessConnection)

    public var id: UUID {
        switch self {
        case .paperless(let value): value.id
        }
    }
    public var name: String {
        switch self {
        case .paperless(let value): value.name
        }
    }
    func validated() throws -> FileStorageConnection {
        switch self {
        case .paperless(let value): .paperless(try value.validated())
        }
    }
}

public struct FileStorageKeychainAccess: Sendable {
    let read: @Sendable (UUID) -> (OSStatus, Data?)
    let write: @Sendable (UUID, Data) -> OSStatus
    let remove: @Sendable (UUID) -> OSStatus
    public init(
        read: @escaping @Sendable (UUID) -> (OSStatus, Data?), write: @escaping @Sendable (UUID, Data) -> OSStatus,
        remove: @escaping @Sendable (UUID) -> OSStatus
    ) {
        self.read = read
        self.write = write
        self.remove = remove
    }
    static var system: Self {
        @Sendable func query(_ id: UUID) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.makosh.files.tokens.v1",
                kSecAttrAccount as String: id.uuidString,
            ]
        }
        return Self(
            read: { id in MakoshSecretStore.shared.copyData(query(id)) },
            write: { id, data in
                let attributes: [String: Any] = [kSecValueData as String: data]
                let status = MakoshSecretStore.shared.updateItem(query(id), attributes)
                if status != errSecItemNotFound { return status }
                return MakoshSecretStore.shared.addItem(query(id).merging(attributes) { _, new in new })
            }, remove: { id in MakoshSecretStore.shared.deleteItem(query(id)) })
    }
}

/// Storage tokens stay in the Keychain only; an empty token means no item.
public actor FileStorageTokenVault {
    private static let limit = 16 * 1024
    private let access: FileStorageKeychainAccess
    public init(access: FileStorageKeychainAccess? = nil) { self.access = access ?? .system }

    public func load(connectionID: UUID) throws -> String? {
        let (status, data) = access.read(connectionID)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= Self.limit, let token = String(data: data, encoding: .utf8) else {
            throw FilesFailure.keyUnavailable
        }
        return token
    }
    public func save(_ token: String, connectionID: UUID) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return try remove(connectionID: connectionID) }
        let data = Data(trimmed.utf8)
        guard data.count <= Self.limit, access.write(connectionID, data) == errSecSuccess else { throw FilesFailure.keyUnavailable }
    }
    public func remove(connectionID: UUID) throws {
        let result = access.remove(connectionID)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw FilesFailure.keyUnavailable }
    }
}

/// The list of connections as JSON in UserDefaults (no secrets); tokens go to the vault.
public final class FileStorageRegistry: @unchecked Sendable {
    public static let key = "makosh.files.storages.v1"
    private let defaults: UserDefaults
    private let vault: FileStorageTokenVault
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, vault: FileStorageTokenVault) {
        self.defaults = defaults
        self.vault = vault
    }

    public func connections() -> [FileStorageConnection] {
        lock.withLock {
            guard let data = defaults.data(forKey: Self.key) else { return [] }
            return (try? JSONDecoder().decode([FileStorageConnection].self, from: data)) ?? []
        }
    }

    /// Validates first; a nil token keeps whatever token the connection already has.
    public func save(_ connection: FileStorageConnection, token: String?) async throws {
        let valid = try connection.validated()
        if let token {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
                throw FilesFailure.invalidToken
            }
            try await vault.save(trimmed, connectionID: valid.id)
        }
        try write { list in
            if let index = list.firstIndex(where: { $0.id == valid.id }) { list[index] = valid } else { list.append(valid) }
        }
    }

    /// The token goes first: a token that cannot be removed keeps its connection visible.
    public func remove(_ id: UUID) async throws {
        try await vault.remove(connectionID: id)
        try write { list in list.removeAll { $0.id == id } }
    }

    private func write(_ change: (inout [FileStorageConnection]) -> Void) throws {
        try lock.withLock {
            var list = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([FileStorageConnection].self, from: $0) } ?? []
            change(&list)
            defaults.set(try JSONEncoder().encode(list), forKey: Self.key)
        }
    }
}

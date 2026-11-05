import Foundation
import MakoshCore
import Security

public struct AIKeychainAccess: Sendable {
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
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.makosh.ai.tokens.v1",
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

public protocol AITokenStoring: Sendable {
    func load(connectionID: UUID) async throws -> String?
    func save(_ token: String, connectionID: UUID) async throws
    func remove(connectionID: UUID) async throws
}

/// API tokens stay in the Keychain only; an empty token (local servers) means no item.
public actor AITokenVault: AITokenStoring {
    private static let limit = 16 * 1024
    private let access: AIKeychainAccess
    public init(access: AIKeychainAccess? = nil) { self.access = access ?? .system }
    public func load(connectionID: UUID) throws -> String? {
        let (status, data) = access.read(connectionID)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= Self.limit, let token = String(data: data, encoding: .utf8) else {
            throw AIFailure.keyUnavailable
        }
        return token
    }
    public func save(_ token: String, connectionID: UUID) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return try remove(connectionID: connectionID) }
        let data = Data(trimmed.utf8)
        guard data.count <= Self.limit, access.write(connectionID, data) == errSecSuccess else { throw AIFailure.keyUnavailable }
    }
    public func remove(connectionID: UUID) throws {
        let result = access.remove(connectionID)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw AIFailure.keyUnavailable }
    }
}

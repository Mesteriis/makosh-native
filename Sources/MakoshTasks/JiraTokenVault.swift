import Foundation
import MakoshCore
import Security

/// How tokens reach the Keychain; the system store by default, memory for tests and QA.
public struct JiraKeychainAccess: Sendable {
    public let read: @Sendable (UUID) -> (OSStatus, Data?)
    public let write: @Sendable (UUID, Data) -> OSStatus
    public let remove: @Sendable (UUID) -> OSStatus
    public init(
        read: @escaping @Sendable (UUID) -> (OSStatus, Data?), write: @escaping @Sendable (UUID, Data) -> OSStatus,
        remove: @escaping @Sendable (UUID) -> OSStatus
    ) {
        self.read = read
        self.write = write
        self.remove = remove
    }

    public static var system: Self {
        @Sendable func query(_ id: UUID) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.makosh.jira.tokens.v1",
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

    /// An in-memory Keychain for tests and the synthetic preview.
    public static func memory() -> Self {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var items: [UUID: Data] = [:]
        }
        let box = Box()
        return Self(
            read: { id in box.lock.withLock { box.items[id].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) } },
            write: { id, data in
                box.lock.withLock { box.items[id] = data }
                return errSecSuccess
            }, remove: { id in box.lock.withLock { box.items.removeValue(forKey: id) == nil ? errSecItemNotFound : errSecSuccess } })
    }
}

/// API tokens stay in the Keychain only; an empty token means no item.
public actor JiraTokenVault {
    private static let limit = 16 * 1024
    private let access: JiraKeychainAccess
    public init(access: JiraKeychainAccess = .system) { self.access = access }

    public func load(connectionID: UUID) throws -> String? {
        let (status, data) = access.read(connectionID)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= Self.limit, let token = String(data: data, encoding: .utf8) else {
            throw TasksFailure.keyUnavailable
        }
        return token
    }

    public func save(_ token: String, connectionID: UUID) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return try remove(connectionID: connectionID) }
        guard trimmed.rangeOfCharacter(from: .newlines) == nil, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TasksFailure.invalidToken
        }
        let data = Data(trimmed.utf8)
        guard data.count <= Self.limit, access.write(connectionID, data) == errSecSuccess else { throw TasksFailure.keyUnavailable }
    }

    public func remove(connectionID: UUID) throws {
        let result = access.remove(connectionID)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw TasksFailure.keyUnavailable }
    }
}

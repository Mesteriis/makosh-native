import Foundation
import Security

public struct TelemostKeychainAccess: Sendable {
    let read: @Sendable (UUID) -> (OSStatus, Data?)
    let write: @Sendable (UUID, Data) -> OSStatus
    let remove: @Sendable (UUID) -> OSStatus
    public init(read: @escaping @Sendable (UUID) -> (OSStatus, Data?), write: @escaping @Sendable (UUID, Data) -> OSStatus, remove: @escaping @Sendable (UUID) -> OSStatus) {
        self.read = read; self.write = write; self.remove = remove
    }
    static var system: Self {
        @Sendable func query(_ id: UUID) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.makosh.telemost.tokens.v1", kSecAttrAccount as String: id.uuidString]
        }
        return Self(read: { id in
            var attributes = query(id); attributes[kSecReturnData as String] = true; attributes[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(attributes as CFDictionary, &result)
            return (status, result as? Data)
        }, write: { id, data in
            let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
            if status != errSecItemNotFound { return status }
            return SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil)
        }, remove: { id in SecItemDelete(query(id) as CFDictionary) })
    }
}
public protocol TelemostTokenStoring: Sendable {
    func load(accountID: UUID) async throws -> TelemostToken?
    func save(_ token: TelemostToken, accountID: UUID) async throws
    func remove(accountID: UUID) async throws
}
public actor TelemostTokenVault: TelemostTokenStoring {
    private let access: TelemostKeychainAccess
    public init(access: TelemostKeychainAccess? = nil) { self.access = access ?? .system }
    public func load(accountID: UUID) throws -> TelemostToken? {
        let (status, data) = access.read(accountID)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= 512 * 1024,
              let token = try? JSONDecoder().decode(TelemostToken.self, from: data) else { throw TelemostFailure.keyUnavailable }
        try token.validate(); return token
    }
    public func save(_ token: TelemostToken, accountID: UUID) throws {
        try token.validate()
        let data = try JSONEncoder().encode(token)
        guard data.count <= 512 * 1024, access.write(accountID, data) == errSecSuccess else { throw TelemostFailure.keyUnavailable }
    }
    public func remove(accountID: UUID) throws {
        let result = access.remove(accountID)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw TelemostFailure.keyUnavailable }
    }
}

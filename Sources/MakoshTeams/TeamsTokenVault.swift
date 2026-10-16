import Foundation
import Security

protocol TeamsKeychainAPI: Sendable {
    func copy(account: String) -> (OSStatus, Data?)
    func update(account: String, data: Data) -> OSStatus
    func add(account: String, data: Data) -> OSStatus
}

struct TeamsSystemKeychain: TeamsKeychainAPI {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.makosh.teams.oauth",
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func copy(account: String) -> (OSStatus, Data?) {
        var request = query(account)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        return (status, value as? Data)
    }
    func update(account: String, data: Data) -> OSStatus {
        SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }
    func add(account: String, data: Data) -> OSStatus {
        var request = query(account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        request[kSecAttrLabel as String] = "Макош · Teams"
        return SecItemAdd(request as CFDictionary, nil)
    }
}

protocol TeamsTokenStoring: Sendable {
    func load(accountID: UUID) async throws -> TeamsTokenBundle?
    func save(_ bundle: TeamsTokenBundle, accountID: UUID, permit: TeamsAuthorizationPermit?) async throws
}

extension TeamsTokenStoring {
    func save(_ bundle: TeamsTokenBundle, accountID: UUID) async throws { try await save(bundle, accountID: accountID, permit: nil) }
}

actor TeamsTokenVault: TeamsTokenStoring {
    private let api: any TeamsKeychainAPI
    init(api: any TeamsKeychainAPI = TeamsSystemKeychain()) { self.api = api }
    func load(accountID: UUID) throws -> TeamsTokenBundle? {
        let (status, data) = api.copy(account: accountID.uuidString)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= 512 * 1024,
              let bundle = try? JSONDecoder().decode(TeamsTokenBundle.self, from: data), !bundle.accessToken.isEmpty else { throw TeamsFailure.credentialStorage }
        return bundle
    }
    func save(_ bundle: TeamsTokenBundle, accountID: UUID, permit: TeamsAuthorizationPermit? = nil) throws {
        if let permit { try permit.perform { try write(bundle, accountID: accountID) } }
        else { try write(bundle, accountID: accountID) }
    }
    private func write(_ bundle: TeamsTokenBundle, accountID: UUID) throws {
        guard let data = try? JSONEncoder().encode(bundle), data.count <= 512 * 1024, !bundle.accessToken.isEmpty else { throw TeamsFailure.credentialStorage }
        let status = api.update(account: accountID.uuidString, data: data)
        if status == errSecItemNotFound {
            guard api.add(account: accountID.uuidString, data: data) == errSecSuccess else { throw TeamsFailure.credentialStorage }
        } else if status != errSecSuccess { throw TeamsFailure.credentialStorage }
    }
}

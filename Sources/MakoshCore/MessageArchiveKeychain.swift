import Foundation
import Security

/// A separate archive key in the macOS login Keychain, with its normal OS ACL.
/// Ad-hoc development apps cannot use the entitlement-gated data-protection
/// Keychain. This deliberately selects the supported macOS store, with no
/// automatic fallback or claim of iOS device-only/lock-screen accessibility.
/// Called only by an explicitly opened archive/connection, never by a view initializer.
public enum MessageArchiveKeychain {
    public static func existing(vaultID: UUID) throws -> Data? {
        try existing(vaultID: vaultID, lookup: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        })
    }
    public static func install(vaultID: UUID, key: Data) throws {
        try install(vaultID: vaultID, key: key, lookup: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }, add: { SecItemAdd($0 as CFDictionary, nil) })
    }
    static func existing(vaultID: UUID, lookup: ([String: Any]) -> (OSStatus, Data?)) throws -> Data? {
        var query = baseQuery(vaultID)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, value) = lookup(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let value, value.count == 32 else { throw MessageArchiveError.keyUnavailable }
        return value
    }
    static func install(vaultID: UUID, key: Data, lookup: ([String: Any]) -> (OSStatus, Data?), add: ([String: Any]) -> OSStatus) throws {
        guard key.count == 32 else { throw MessageArchiveError.keyUnavailable }
        let installed = try open(vaultID: vaultID, allowCreation: true, lookup: lookup, add: add, random: { key })
        guard installed == key else { throw MessageArchiveError.keyUnavailable }
    }
    private static func baseQuery(_ vaultID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.makosh.message-archive",
            kSecAttrAccount as String: vaultID.uuidString.lowercased(),
            kSecAttrSynchronizable as String: false
        ]
    }
    public static func open(vaultID: UUID, allowCreation: Bool) throws -> Data {
        try open(vaultID: vaultID, allowCreation: allowCreation,
                 lookup: { query in
                     var result: CFTypeRef?
                     let status = SecItemCopyMatching(query as CFDictionary, &result)
                     return (status, result as? Data)
                 }, add: { SecItemAdd($0 as CFDictionary, nil) },
                 random: {
                     var bytes = Data(count: 32)
                     guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
                         throw MessageArchiveError.keyUnavailable
                     }
                     return bytes
                 })
    }

    // Injected system operations let tests prove missing/existing/duplicate/locked
    // behavior without opening the user's Keychain or creating a real item.
    static func open(vaultID: UUID, allowCreation: Bool,
                     lookup: ([String: Any]) -> (OSStatus, Data?),
                     add: ([String: Any]) -> OSStatus, random: () throws -> Data) throws -> Data {
        let query = baseQuery(vaultID)
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, value) = lookup(read)
        if status == errSecSuccess {
            guard let value, value.count == 32 else { throw MessageArchiveError.keyUnavailable }
            return value
        }
        guard status == errSecItemNotFound, allowCreation else { throw MessageArchiveError.keyUnavailable }
        let bytes = try random()
        guard bytes.count == 32 else { throw MessageArchiveError.keyUnavailable }
        var item = query
        item[kSecValueData as String] = bytes
        let added = add(item)
        if added == errSecDuplicateItem {
            let (status, existing) = lookup(read)
            guard status == errSecSuccess, let existing, existing.count == 32 else { throw MessageArchiveError.keyUnavailable }
            return existing
        }
        guard added == errSecSuccess else { throw MessageArchiveError.keyUnavailable }
        return bytes
    }
}

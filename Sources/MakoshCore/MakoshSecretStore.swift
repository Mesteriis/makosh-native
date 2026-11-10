import Foundation
import Security

/// One Keychain generic-password value and its `kSecAttrGeneric` tag.
public struct MakoshSecret: Codable, Equatable, Sendable {
    public var data: Data
    public var generic: Data?
    public init(data: Data, generic: Data? = nil) {
        self.data = data
        self.generic = generic
    }
}

/// The Keychain operations the store needs; tests substitute an in-memory one.
protocol MakoshSecretKeychain: Sendable {
    func readBlob() -> (OSStatus, Data?)
    func writeBlob(_ data: Data) -> OSStatus
    func readLegacy(service: String, account: String) -> (OSStatus, MakoshSecret?)
    func deleteLegacy(service: String, account: String) -> OSStatus
}

/// Every Makosh secret in one login-Keychain item, so an ad-hoc signed build
/// asks for Keychain access once instead of once per service. Values are
/// cached in memory for the process. Calls return Keychain status codes so
/// each service keeps its own fail-closed handling.
///
/// Items written before this store stay where they are: a secret missing
/// here is read from its own item once and copied in. A deleted secret is
/// remembered, so its old item can never bring it back. Every write re-reads
/// the shared item and changes only its own entry under an exclusive lock on
/// a file, so another process (a QA bundle shares the item) can neither lose
/// its entries nor add the same name twice.
public final class MakoshSecretStore: @unchecked Sendable {
    public static let shared = MakoshSecretStore(
        keychain: MakoshSystemSecretKeychain(), lockURL: MakoshInstanceLock.lockURL(named: "secrets"))

    private struct Contents: Codable {
        var version = 1
        var secrets: [String: MakoshSecret] = [:]
        var deleted: Set<String> = []
    }
    private let keychain: any MakoshSecretKeychain
    /// The file every process locks around its read-change-write of the item.
    private let lockURL: URL
    private let lock = NSLock()
    private var cache: Contents?

    init(keychain: any MakoshSecretKeychain, lockURL: URL) {
        self.keychain = keychain
        self.lockURL = lockURL
    }

    public func read(service: String, account: String) -> (OSStatus, MakoshSecret?) {
        lock.withLock {
            let name = Self.name(service, account)
            let contents: Contents
            switch load() {
            case .failure(let error): return (error.status, nil)
            case .success(let loaded): contents = loaded
            }
            if let secret = contents.secrets[name] { return (errSecSuccess, secret) }
            if contents.deleted.contains(name) { return (errSecItemNotFound, nil) }
            let (status, legacy) = keychain.readLegacy(service: service, account: account)
            guard status == errSecSuccess, let legacy else { return (status, nil) }
            let saved = change { contents in
                contents.secrets[name] = legacy
                return true
            }
            return saved == errSecSuccess ? (errSecSuccess, legacy) : (saved, nil)
        }
    }

    /// `errSecDuplicateItem` when the secret exists, as `SecItemAdd` reports.
    public func add(service: String, account: String, secret: MakoshSecret) -> OSStatus {
        let (status, _) = read(service: service, account: account)
        if status == errSecSuccess { return errSecDuplicateItem }
        guard status == errSecItemNotFound else { return status }
        let name = Self.name(service, account)
        return lock.withLock {
            var duplicate = false
            let saved = change { contents in
                // Another process may have added it since the cached read above.
                if contents.secrets[name] != nil {
                    duplicate = true
                    return false
                }
                contents.secrets[name] = secret
                return true
            }
            return duplicate ? errSecDuplicateItem : saved
        }
    }

    /// `errSecItemNotFound` when the secret is missing or its generic tag
    /// differs from `matchingGeneric`, as a matching `SecItemUpdate` reports.
    public func update(service: String, account: String, secret: MakoshSecret, matchingGeneric: Data? = nil) -> OSStatus {
        let (status, current) = read(service: service, account: account)
        guard status == errSecSuccess, let current else { return status }
        if let matchingGeneric, current.generic != matchingGeneric { return errSecItemNotFound }
        let name = Self.name(service, account)
        return lock.withLock {
            var conflict = false
            let saved = change { contents in
                // Another writer may have replaced it since the read above.
                if let matchingGeneric, contents.secrets[name]?.generic != matchingGeneric {
                    conflict = true
                    return false
                }
                contents.secrets[name] = secret
                return true
            }
            return conflict ? errSecItemNotFound : saved
        }
    }

    public func delete(service: String, account: String) -> OSStatus {
        let (status, _) = read(service: service, account: account)
        guard status == errSecSuccess else { return status }
        let name = Self.name(service, account)
        return lock.withLock {
            let saved = change { contents in
                contents.secrets[name] = nil
                contents.deleted.insert(name)
                return true
            }
            guard saved == errSecSuccess else { return saved }
            // Best effort: the tombstone already keeps it gone from Makosh.
            _ = keychain.deleteLegacy(service: service, account: account)
            return errSecSuccess
        }
    }

    // MARK: Shared item

    private static func name(_ service: String, _ account: String) -> String { service + "\u{1F}" + account }

    /// Must be called with the lock held.
    private func load() -> Result<Contents, StatusError> {
        if let cache { return .success(cache) }
        switch fresh() {
        case .success(let contents):
            cache = contents
            return .success(contents)
        case .failure(let error): return .failure(error)
        }
    }

    private struct StatusError: Error {
        let status: OSStatus
    }

    private func fresh() -> Result<Contents, StatusError> {
        let (status, data) = keychain.readBlob()
        if status == errSecItemNotFound { return .success(Contents()) }
        guard status == errSecSuccess, let data else {
            return .failure(StatusError(status: status == errSecSuccess ? errSecDecode : status))
        }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data), contents.version == 1 else {
            return .failure(StatusError(status: errSecDecode))
        }
        return .success(contents)
    }

    /// Re-reads the shared item, applies one entry's change and writes it
    /// back when `apply` returns true; otherwise the fresh contents only
    /// refresh the cache. Must be called with the lock held. The re-read and
    /// the write run under an exclusive `flock` on the lock file, so another
    /// process's change between them cannot be lost; a lock file that cannot
    /// be taken fails closed, like a refused Keychain prompt.
    private func change(_ apply: (inout Contents) -> Bool) -> OSStatus {
        let descriptor = MakoshInstanceLock.openLockFile(at: lockURL)
        guard descriptor >= 0 else { return errSecIO }
        defer { close(descriptor) }  // closing the descriptor releases the lock
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { return errSecIO }
        }
        var contents: Contents
        switch fresh() {
        case .success(let current): contents = current
        case .failure(let error): return error.status
        }
        let current = contents
        guard apply(&contents) else {
            cache = current
            return errSecSuccess
        }
        guard let data = try? JSONEncoder().encode(contents) else { return errSecParam }
        let status = keychain.writeBlob(data)
        if status == errSecSuccess { cache = contents }
        return status
    }
}

/// The login Keychain. The shared item and the legacy per-service items are
/// non-synchronizable generic passwords readable after first unlock on this Mac.
struct MakoshSystemSecretKeychain: MakoshSecretKeychain {
    private static let service = "org.makosh.secrets"
    private static let account = "v1"
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account, kSecAttrSynchronizable as String: false,
        ]
    }

    func readBlob() -> (OSStatus, Data?) {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        return (status, result as? Data)
    }

    func writeBlob(_ data: Data) -> OSStatus {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Макош · секреты"
        return SecItemAdd(item as CFDictionary, nil)
    }

    func readLegacy(service: String, account: String) -> (OSStatus, MakoshSecret?) {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else { return (errSecDecode, nil) }
        return (errSecSuccess, MakoshSecret(data: data, generic: item[kSecAttrGeneric as String] as? Data))
    }

    func deleteLegacy(service: String, account: String) -> OSStatus {
        SecItemDelete(
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
                as CFDictionary)
    }
}

/// Adapters for vaults written against `SecItem` dictionaries: the query's
/// service and account select the secret, `kSecValueData` and
/// `kSecAttrGeneric` carry its value, and a generic tag in an update query
/// makes the update conditional, as `SecItemUpdate` matching does.
extension MakoshSecretStore {
    public func copyData(_ query: [String: Any]) -> (OSStatus, Data?) {
        guard let (service, account) = Self.address(query) else { return (errSecParam, nil) }
        let (status, secret) = read(service: service, account: account)
        return (status, secret?.data)
    }

    public func copyAttributes(_ query: [String: Any]) -> (OSStatus, [String: Any]?) {
        guard let (service, account) = Self.address(query) else { return (errSecParam, nil) }
        let (status, secret) = read(service: service, account: account)
        guard let secret else { return (status, nil) }
        var attributes: [String: Any] = [kSecValueData as String: secret.data]
        if let generic = secret.generic { attributes[kSecAttrGeneric as String] = generic }
        return (status, attributes)
    }

    public func addItem(_ item: [String: Any]) -> OSStatus {
        guard let (service, account) = Self.address(item), let data = item[kSecValueData as String] as? Data else { return errSecParam }
        return add(service: service, account: account, secret: MakoshSecret(data: data, generic: item[kSecAttrGeneric as String] as? Data))
    }

    public func updateItem(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        guard let (service, account) = Self.address(query), let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        let expected = query[kSecAttrGeneric as String] as? Data
        let (status, current) = read(service: service, account: account)
        guard status == errSecSuccess, let current else { return status }
        let generic = attributes[kSecAttrGeneric as String] as? Data ?? current.generic
        return update(service: service, account: account, secret: MakoshSecret(data: data, generic: generic), matchingGeneric: expected)
    }

    public func deleteItem(_ query: [String: Any]) -> OSStatus {
        guard let (service, account) = Self.address(query) else { return errSecParam }
        return delete(service: service, account: account)
    }

    private static func address(_ query: [String: Any]) -> (String, String)? {
        guard let service = query[kSecAttrService as String] as? String, let account = query[kSecAttrAccount as String] as? String
        else { return nil }
        return (service, account)
    }
}

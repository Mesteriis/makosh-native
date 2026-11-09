import CryptoKit
import Foundation
import MakoshGoogle
import Security

/// Every secret of the OSINT module, in one Keychain service: the SSH password, the flowsint
/// service password, the backup of the server's `.env` secrets, third-party API keys and the key
/// that hashes values in the attempt journal. Nothing here reaches PostgreSQL or the logs.
public actor OSINTCredentialVault {
    public static let service = "org.makosh.osint.v1"
    static let sshAccount = "ssh-password"
    static let serviceAccount = "service-password"
    static let hmacAccount = "payload-hmac"
    static let envPrefix = "env."
    static let keyPrefix = "key."
    private static let limit = 16 * 1024
    private let access: KeychainAccess

    public init(access: KeychainAccess = .system) { self.access = access }

    // MARK: Passwords and keys

    public func saveSSHPassword(_ password: String) throws { try save(Self.sshAccount, password) }
    public func sshPassword() throws -> String? { try read(Self.sshAccount) }

    public func saveServicePassword(_ password: String) throws { try save(Self.serviceAccount, password) }
    public func servicePassword() throws -> String? { try read(Self.serviceAccount) }

    public func saveEnvSecret(name: String, _ value: String) throws { try save(Self.envPrefix + name, value) }
    public func envSecret(name: String) throws -> String? { try read(Self.envPrefix + name) }

    public func saveKey(name: String, _ value: String) throws { try save(Self.keyPrefix + name, value) }
    public func key(name: String) throws -> String? { try read(Self.keyPrefix + name) }
    public func removeKey(name: String) throws { try remove(Self.keyPrefix + name) }

    // MARK: Journal HMAC

    /// Creates the 32-byte journal key once; an existing key is kept so old digests stay comparable.
    public func ensureHMACKey() throws {
        if try readData(Self.hmacAccount) != nil { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OSINTFailure.storage("random") }
        guard access.write(Self.service, Self.hmacAccount, Data(bytes)) == errSecSuccess else { throw OSINTFailure.storage("keychain") }
    }

    /// HMAC-SHA256 (hex) of the value in lower case without surrounding whitespace; nil without a key.
    public func hmac(_ value: String) throws -> String? {
        guard let keyData = try readData(Self.hmacAccount) else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: SymmetricKey(data: keyData))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Removes every secret of the module, including the journal key.
    public func removeAll() throws {
        for account in knownAccounts() { try remove(account) }
    }

    // MARK: Plumbing

    private var removable: [String] = []

    private func knownAccounts() -> [String] {
        var accounts = Set([Self.sshAccount, Self.serviceAccount, Self.hmacAccount])
        accounts.formUnion(removable)
        return accounts.sorted()
    }

    private func save(_ account: String, _ value: String) throws {
        guard !value.isEmpty, value.rangeOfCharacter(from: .controlCharacters) == nil else { throw OSINTFailure.storage("secret") }
        let data = Data(value.utf8)
        guard data.count <= Self.limit else { throw OSINTFailure.storage("secret") }
        guard access.write(Self.service, account, data) == errSecSuccess else { throw OSINTFailure.storage("keychain") }
        if account.hasPrefix(Self.envPrefix) || account.hasPrefix(Self.keyPrefix), !removable.contains(account) {
            removable.append(account)
        }
    }

    private func read(_ account: String) throws -> String? {
        guard let data = try readData(account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw OSINTFailure.storage("keychain") }
        return value
    }

    private func readData(_ account: String) throws -> Data? {
        let (status, data) = access.read(Self.service, account)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw OSINTFailure.storage("keychain") }
        return data
    }

    private func remove(_ account: String) throws {
        let status = access.remove(Self.service, account)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OSINTFailure.storage("keychain") }
    }
}

import Foundation
import Security
import Postbox

/// Session storage and Keychain work belong to the Telegram service executor.
actor TelegramSessionWorker {
    struct Prepared: Sendable {
        let directory: URL
        let keyBytes: Data
        var encryption: ValueBoxEncryptionParameters {
            get throws {
                guard let key = ValueBoxEncryptionParameters.Key(data: keyBytes.prefix(32)),
                      let salt = ValueBoxEncryptionParameters.Salt(data: keyBytes.suffix(16)), keyBytes.count == 48 else {
                    throw TelegramSetupError.keychain
                }
                return .init(forceEncryptionIfNoSet: true, key: key, salt: salt)
            }
        }
    }
    private let directoryOverride: URL?
    private let readKey: @Sendable (URL) throws -> Data
    init(directory: URL? = nil,
         readKey: @escaping @Sendable (URL) throws -> Data = TelegramSessionKey.bytes) {
        directoryOverride = directory; self.readKey = readKey
    }
    func prepare() throws -> Prepared {
        try Task.checkCancellation()
        let directory = try directoryOverride ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Makosh/Telegram", isDirectory: true)
        let bytes = try readKey(directory)
        guard bytes.count == 48 else { throw TelegramSetupError.keychain }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return .init(directory: directory, keyBytes: bytes)
    }
}

private enum TelegramSessionKey {
    static func bytes(directory: URL) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.makosh.telegram", kSecAttrAccount as String: "session-encryption-v1"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        let bytes: Data
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 48 else { throw TelegramSetupError.keychain }
            bytes = data
        } else if status == errSecItemNotFound {
            if FileManager.default.fileExists(atPath: directory.path),
               !(try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty { throw TelegramSetupError.missingSessionKey }
            var generated = Data(count: 48)
            guard generated.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 48, $0.baseAddress!) }) == errSecSuccess else { throw TelegramSetupError.keychain }
            var item = query
            item[kSecValueData as String] = generated
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw TelegramSetupError.keychain }
            bytes = generated
        } else { throw TelegramSetupError.keychain }
        return bytes
    }
}

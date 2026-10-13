import Foundation
import Security

struct TelegramProxyRecord: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let configuration: TelegramProxyConfiguration
    let token: Data?
    var description: String { "TelegramProxyRecord(redacted)" }
    var debugDescription: String { description }
}
@MainActor final class TelegramProxyVault {
    typealias Lookup = ([String: Any]) -> (OSStatus, [String: Any]?)
    private let lookup: Lookup
    private let add: ([String: Any]) -> OSStatus
    private let update: ([String: Any], [String: Any]) -> OSStatus
    private struct Stored: Codable { let version: Int; let configuration: TelegramProxyConfiguration }
    private var query: [String: Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"org.makosh.telegram.proxy",
         kSecAttrAccount as String:"settings.v1", kSecAttrSynchronizable as String:false]
    }
    init(lookup: @escaping Lookup = { query in
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        return (result, value as? [String: Any])
    }, add: @escaping ([String: Any]) -> OSStatus = { SecItemAdd($0 as CFDictionary, nil) },
        update: @escaping ([String: Any], [String: Any]) -> OSStatus = { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) }) {
        self.lookup = lookup; self.add = add; self.update = update
    }
    func read() throws -> TelegramProxyRecord {
        var request = query
        request[kSecReturnData as String] = true; request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = lookup(request)
        if status == errSecItemNotFound { return .init(configuration: .init(), token: nil) }
        guard status == errSecSuccess, let item, let data = item[kSecValueData as String] as? Data, data.count <= 65_536,
              let token = item[kSecAttrGeneric as String] as? Data, token.count == 16,
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1,
              stored.configuration.isValid else { throw TelegramProxyError.unavailable }
        return .init(configuration: stored.configuration, token: token)
    }
    func save(_ configuration: TelegramProxyConfiguration, expected: TelegramProxyRecord) throws -> TelegramProxyRecord {
        guard configuration.isValid, expected.configuration.isValid,
              let data = try? JSONEncoder().encode(Stored(version: 1, configuration: configuration)), data.count <= 65_536 else { throw TelegramProxyError.invalid }
        var uuid = UUID().uuid
        let token = withUnsafeBytes(of: &uuid) { Data($0) }
        let status: OSStatus
        if let previous = expected.token {
            guard previous.count == 16 else { throw TelegramProxyError.invalid }
            var matching = query; matching[kSecAttrGeneric as String] = previous
            // SecItemUpdate matches this real item attribute atomically. No
            // read-then-unconditional overwrite, default-Keychain fallback or delete.
            status = update(matching, [kSecValueData as String:data, kSecAttrGeneric as String:token])
        } else {
            guard expected.configuration == TelegramProxyConfiguration() else { throw TelegramProxyError.changed }
            var item = query; item[kSecValueData as String] = data; item[kSecAttrGeneric as String] = token
            item[kSecAttrLabel as String] = "Макош · прокси Telegram"
            status = add(item)
        }
        if status == errSecDuplicateItem || status == errSecItemNotFound { throw TelegramProxyError.changed }
        guard status == errSecSuccess else { throw TelegramProxyError.unavailable }
        let confirmed = try read()
        guard confirmed.token == token, confirmed.configuration == configuration else { throw TelegramProxyError.changed }
        return confirmed
    }
}

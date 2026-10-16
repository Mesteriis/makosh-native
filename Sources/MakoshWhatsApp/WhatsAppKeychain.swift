import Foundation
import Security

enum WhatsAppKeychain {
  static func open(account: UUID, allowCreation: Bool) throws -> Data {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "org.makosh.whatsapp.session",
      kSecAttrAccount as String: account.uuidString.lowercased(),
      kSecAttrSynchronizable as String: false,
    ]
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecSuccess {
      guard let data = value as? Data, data.count == 32 else { throw WhatsAppFailure.key }
      return data
    }
    guard status == errSecItemNotFound, allowCreation else { throw WhatsAppFailure.key }
    var key = Data(count: 32)
    guard
      key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) })
        == errSecSuccess
    else { throw WhatsAppFailure.key }
    var add = base
    add[kSecValueData as String] = key
    add[kSecAttrLabel as String] = "Макош · WhatsApp session"
    let added = SecItemAdd(add as CFDictionary, nil)
    if added == errSecDuplicateItem { return try open(account: account, allowCreation: false) }
    guard added == errSecSuccess else { throw WhatsAppFailure.key }
    return key
  }
}

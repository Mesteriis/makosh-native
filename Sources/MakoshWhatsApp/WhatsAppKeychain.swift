import Foundation
import MakoshCore
import Security

enum WhatsAppKeychain {
  static func open(account: UUID, allowCreation: Bool) throws -> Data {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "org.makosh.whatsapp.session",
      kSecAttrAccount as String: account.uuidString.lowercased(),
      kSecAttrSynchronizable as String: false,
    ]
    let (status, value) = MakoshSecretStore.shared.copyData(base)
    if status == errSecSuccess {
      guard let data = value, data.count == 32 else { throw WhatsAppFailure.key }
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
    let added = MakoshSecretStore.shared.addItem(add)
    if added == errSecDuplicateItem { return try open(account: account, allowCreation: false) }
    guard added == errSecSuccess else { throw WhatsAppFailure.key }
    return key
  }
}

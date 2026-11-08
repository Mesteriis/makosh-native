import Foundation
import MakoshCore
import Security

/// How credentials reach the Keychain: the shared Makosh item by default, memory for tests and QA.
public struct KeychainAccess: Sendable {
    public let read: @Sendable (String, String) -> (OSStatus, Data?)
    public let write: @Sendable (String, String, Data) -> OSStatus
    public let remove: @Sendable (String, String) -> OSStatus

    public init(
        read: @escaping @Sendable (String, String) -> (OSStatus, Data?), write: @escaping @Sendable (String, String, Data) -> OSStatus,
        remove: @escaping @Sendable (String, String) -> OSStatus
    ) {
        self.read = read
        self.write = write
        self.remove = remove
    }

    public static var system: Self {
        @Sendable func query(_ service: String, _ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }
        return Self(
            read: { service, account in MakoshSecretStore.shared.copyData(query(service, account)) },
            write: { service, account, data in
                let attributes: [String: Any] = [kSecValueData as String: data]
                let status = MakoshSecretStore.shared.updateItem(query(service, account), attributes)
                if status != errSecItemNotFound { return status }
                return MakoshSecretStore.shared.addItem(query(service, account).merging(attributes) { _, new in new })
            }, remove: { service, account in MakoshSecretStore.shared.deleteItem(query(service, account)) })
    }

    public static func memory() -> Self {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var items: [String: Data] = [:]
        }
        let box = Box()
        return Self(
            read: { s, a in box.lock.withLock { box.items[s + "/" + a].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) } },
            write: { s, a, data in
                box.lock.withLock { box.items[s + "/" + a] = data }
                return errSecSuccess
            },
            remove: { s, a in box.lock.withLock { box.items.removeValue(forKey: s + "/" + a) == nil ? errSecItemNotFound : errSecSuccess } }
        )
    }
}

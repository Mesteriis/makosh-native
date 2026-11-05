import Foundation
import MakoshCore
import Security

/// Called by the account worker only; secrets never enter Codable settings or logs.
struct MailCredentialVault: Sendable {
    func save(_ value: String, account: String, kind: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16384 else { throw MailFailure.invalidInput }
        let query = base(account, kind)
        let updated = MakoshSecretStore.shared.updateItem(query, [kSecValueData as String: Data(value.utf8)])
        if updated == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            guard MakoshSecretStore.shared.addItem(item) == errSecSuccess else { throw MailFailure.keychain }
        } else if updated != errSecSuccess {
            throw MailFailure.keychain
        }
    }
    func read(account: String, kind: String) throws -> String {
        let (status, value) = MakoshSecretStore.shared.copyData(base(account, kind))
        guard status == errSecSuccess, let data = value, let password = String(data: data, encoding: .utf8) else {
            throw MailFailure.keychain
        }
        return password
    }
    private func base(_ account: String, _ kind: String) -> [String: Any] {
        [kSecAttrService as String: "org.makosh.mail.credentials", kSecAttrAccount as String: account + "." + kind]
    }
}

public struct MailCredentialAccess: Sendable {
    let saveValue: @Sendable (String, String, String) throws -> Void
    let readValue: @Sendable (String, String) throws -> String
    public init(
        save: @escaping @Sendable (String, String, String) throws -> Void,
        read: @escaping @Sendable (String, String) throws -> String
    ) {
        saveValue = save
        readValue = read
    }
    public static var keychain: Self {
        .init(
            save: { try MailCredentialVault().save($0, account: $1, kind: $2) },
            read: { try MailCredentialVault().read(account: $0, kind: $1) })
    }
}

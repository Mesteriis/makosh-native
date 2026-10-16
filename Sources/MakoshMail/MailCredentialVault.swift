import Foundation
import Security

/// Called by the account worker only; secrets never enter Codable settings or logs.
struct MailCredentialVault: Sendable {
    func save(_ value: String,account: String,kind: String) throws {
        guard !value.isEmpty,value.utf8.count<=16384 else { throw MailFailure.invalidInput }
        let query=base(account,kind)
        let updated=SecItemUpdate(query as CFDictionary,[kSecValueData:Data(value.utf8)] as CFDictionary)
        if updated==errSecItemNotFound {
            var item=query;item[kSecValueData]=Data(value.utf8);item[kSecAttrAccessible]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else { throw MailFailure.keychain }
        } else if updated != errSecSuccess { throw MailFailure.keychain }
    }
    func read(account: String,kind: String) throws -> String {
        var query=base(account,kind);query[kSecReturnData]=true;query[kSecMatchLimit]=kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&value)==errSecSuccess,let data=value as? Data,let password=String(data:data,encoding:.utf8) else { throw MailFailure.keychain }
        return password
    }
    private func base(_ account: String,_ kind: String) -> [CFString:Any] {
        [kSecClass:kSecClassGenericPassword,kSecAttrService:"org.makosh.mail.credentials",kSecAttrAccount:account+"."+kind,kSecAttrSynchronizable:false]
    }
}

public struct MailCredentialAccess: Sendable {
    let saveValue: @Sendable (String,String,String) throws -> Void
    let readValue: @Sendable (String,String) throws -> String
    public init(save: @escaping @Sendable (String,String,String) throws -> Void,
                read: @escaping @Sendable (String,String) throws -> String) {
        saveValue=save;readValue=read
    }
    public static var keychain: Self {
        .init(save:{ try MailCredentialVault().save($0,account:$1,kind:$2) },read:{ try MailCredentialVault().read(account:$0,kind:$1) })
    }
}

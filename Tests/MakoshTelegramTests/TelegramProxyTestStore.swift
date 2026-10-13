import Foundation
import Security
@testable import MakoshTelegram

@MainActor final class TelegramProxyTestStore {
    var item: [String: Any]?
    var unavailable = false, failedUpdate = false
    var writes = 0
    func lookup(_ query: [String: Any]) -> (OSStatus, [String: Any]?) {
        if unavailable { return (errSecInteractionNotAllowed,nil) }
        return item.map { (errSecSuccess,$0) } ?? (errSecItemNotFound,nil)
    }
    func add(_ item: [String: Any]) -> OSStatus {
        guard self.item == nil else { return errSecDuplicateItem }; writes += 1; self.item = item; return errSecSuccess
    }
    func update(_ query: [String: Any], _ value: [String: Any]) -> OSStatus {
        if failedUpdate { return errSecAuthFailed }
        guard let old = item, let expected = query[kSecAttrGeneric as String] as? Data,
              expected == old[kSecAttrGeneric as String] as? Data else { return errSecItemNotFound }
        writes += 1; for (key,value) in value { item?[key] = value }; return errSecSuccess
    }
    func vault() -> TelegramProxyVault { .init(lookup: lookup, add: add, update: update) }
}

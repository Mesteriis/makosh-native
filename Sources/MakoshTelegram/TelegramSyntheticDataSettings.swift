#if DEBUG
import Foundation
import Security

extension TelegramProxyController {
    /// Explicit synthetic preview: no Keychain, account or network access.
    static func synthetic(defaults: UserDefaults = .standard) -> TelegramProxyController {
        let store = TelegramSyntheticProxyStore(defaults: defaults)
        return .init(vault: .init(lookup: store.lookup, add: store.add, update: store.update))
    }
}
@MainActor private final class TelegramSyntheticProxyStore {
    private var item: [String: Any]?
    private let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "telegram.synthetic.proxy.data"),
           let token = defaults.data(forKey: "telegram.synthetic.proxy.token") {
            item = [kSecValueData as String:data, kSecAttrGeneric as String:token]
        }
    }
    func lookup(_ query: [String: Any]) -> (OSStatus, [String: Any]?) {
        item.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }
    func add(_ value: [String: Any]) -> OSStatus {
        guard item == nil else { return errSecDuplicateItem }; item = value; save(); return errSecSuccess
    }
    func update(_ query: [String: Any], _ value: [String: Any]) -> OSStatus {
        guard let expected = query[kSecAttrGeneric as String] as? Data,
              expected == item?[kSecAttrGeneric as String] as? Data else { return errSecItemNotFound }
        for (key, value) in value { item?[key] = value }; save(); return errSecSuccess
    }
    private func save() {
        for (attribute, key) in [(kSecValueData, "telegram.synthetic.proxy.data"), (kSecAttrGeneric, "telegram.synthetic.proxy.token")] {
            defaults.set(item?[attribute as String] as? Data, forKey: key)
        }
    }
}
@MainActor final class TelegramSyntheticCacheProvider: TelegramCacheProvider {
    let accountID: Int64 = -1
    private var items: [TelegramCacheItem] = TelegramCacheKind.allCases.enumerated().map { index, kind in
        .init(namespace: 0, id: Int64(index + 1), bytes: Int64(index + 1) * 1_048_576,
            kind: kind, resources: ["synthetic-cloud-\(index)"],peerIDs:index == 1 ? [10007,10010] : [index < 2 ? 10007 : 10010])
    }
    private var snapshot: TelegramCacheSnapshot { .init(accountID: accountID, items: items,peerTitles:[10007:"Синтетический личный чат",10010:"Синтетическая группа"]) }
    func scan(receive: @escaping @MainActor (TelegramCacheSnapshot?) -> Void) -> any TelegramCacheRequest {
        receive(snapshot); return Request()
    }
    func clear(expected: TelegramCacheSnapshot, categories: Set<TelegramCacheKind>, permitted: @escaping @MainActor () -> Bool,
        receive: @escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
        clear(expected:expected,categories:categories,scope:.all,permitted:permitted,receive:receive)
    }
    func clear(expected: TelegramCacheSnapshot, categories: Set<TelegramCacheKind>, scope: TelegramCacheScope, permitted: @escaping @MainActor () -> Bool,
        receive: @escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
        guard expected == snapshot else { receive(.changed(snapshot)); return Request() }
        guard permitted() else { receive(.refused); return Request() }
        let ids = Set(snapshot.selectedItems(categories:categories,scope:scope).map { "\($0.namespace):\($0.id)" })
        receive(.committing); items.removeAll { ids.contains("\($0.namespace):\($0.id)") }; receive(.finished(snapshot)); return Request()
    }
    private final class Request: TelegramCacheRequest { func cancel() {} }
}
#endif

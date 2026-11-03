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
/// Debug-only legacy Foundation boundary: UserDefaults is documented thread-safe
/// (NSUserDefaults.h), but is not Sendable in this SDK. All mutable synthetic
/// state/defaults access is serialized here; only immutable Data attributes leave.
private final class TelegramSyntheticProxyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var item: [String: Any]?
    private let defaults: UserDefaults
    private var loaded = false
    init(defaults: UserDefaults) { self.defaults = defaults }
    func lookup(_ query: [String: Any]) -> (OSStatus, [String: Any]?) {
        lock.withLock { load(); return item.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) }
    }
    func add(_ value: [String: Any]) -> OSStatus {
        lock.withLock {
            load(); guard item == nil else { return errSecDuplicateItem }
            guard let data = value[kSecValueData as String] as? Data,
                  let token = value[kSecAttrGeneric as String] as? Data else { return errSecParam }
            item = [kSecValueData as String: data, kSecAttrGeneric as String: token]
            save(); return errSecSuccess
        }
    }
    func update(_ query: [String: Any], _ value: [String: Any]) -> OSStatus {
        lock.withLock {
            load()
            guard let expected = query[kSecAttrGeneric as String] as? Data,
                  expected == item?[kSecAttrGeneric as String] as? Data else { return errSecItemNotFound }
            guard let data = value[kSecValueData as String] as? Data,
                  let token = value[kSecAttrGeneric as String] as? Data else { return errSecParam }
            item = [kSecValueData as String: data, kSecAttrGeneric as String: token]
            save(); return errSecSuccess
        }
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        if let data = defaults.data(forKey: "telegram.synthetic.proxy.data"),
           let token = defaults.data(forKey: "telegram.synthetic.proxy.token") {
            item = [kSecValueData as String: data, kSecAttrGeneric as String: token]
        }
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
            kind: kind, resources: ["synthetic-cloud-\(index)"],peerIDs:index == 1 ? [10007,10010] : [index < 2 ? 10007 : 10010],modifiedAt:Int64(Date().timeIntervalSince1970) - Int64(index + 1) * 86400)
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
    func evict(expected:TelegramCacheSnapshot,items selected:[TelegramCacheItem],permitted:@escaping @MainActor () -> Bool,receive:@escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
        guard expected == snapshot else { receive(.changed(snapshot)); return Request() }
        guard !selected.isEmpty, selected.allSatisfy(items.contains), permitted() else { receive(.refused); return Request() }
        receive(.committing)
        guard permitted() else { receive(.refused); return Request() }
        items.removeAll { selected.contains($0) }; receive(.finished(snapshot)); return Request()
    }
}
#endif

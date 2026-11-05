import Foundation

/// Accounts the user left connected, reconnected at the next launch. Only an
/// explicit user disconnect forgets one: failures and quitting keep it. The
/// scope is the database schema, so QA schemas never reconnect real accounts.
/// Account identifiers only; no credentials are stored here.
public struct MakoshAutoConnect: @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    public init(scope: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefix = "makosh.autoConnect." + scope + "."
    }

    public func remembered(_ service: String) -> Set<String> {
        Set(defaults.stringArray(forKey: prefix + service) ?? [])
    }

    public func remember(_ service: String, account: String) {
        var accounts = remembered(service)
        guard accounts.insert(account).inserted else { return }
        defaults.set(accounts.sorted(), forKey: prefix + service)
    }

    public func forget(_ service: String, account: String) {
        var accounts = remembered(service)
        guard accounts.remove(account) != nil else { return }
        defaults.set(accounts.sorted(), forKey: prefix + service)
    }
}

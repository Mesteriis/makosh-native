import Foundation
import MakoshCore

/// Which books' new people the reconciliation pass may enrich: the flagged books, and only while
/// the module is on, the host key is trusted and flowsint is installed.
public enum OSINTAutoSources {
    /// A Telegram account is a book and a conversation source at once, and chat partners carry the same
    /// identity as contacts: its flag would send everyone the user ever chatted with. Books only.
    public static func allowsAutomaticEnrichment(service: String) -> Bool { service != "telegram" }

    public static func sources(flaggedBookSources: [ImportSource], settings: OSINTSettings) -> [ImportSource] {
        guard settings.enabled, settings.hostKeyFingerprint != nil, settings.installedSHA != nil else { return [] }
        return flaggedBookSources.filter { allowsAutomaticEnrichment(service: $0.service) }
    }
}

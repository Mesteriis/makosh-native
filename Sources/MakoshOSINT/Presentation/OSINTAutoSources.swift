import Foundation
import MakoshCore

/// Which books' new people the reconciliation pass may enrich: the flagged books, and only while
/// the module is on, the host key is trusted and flowsint is installed.
public enum OSINTAutoSources {
    public static func sources(flaggedBookSources: [ImportSource], settings: OSINTSettings) -> [ImportSource] {
        guard settings.enabled, settings.hostKeyFingerprint != nil, settings.installedSHA != nil else { return [] }
        return flaggedBookSources
    }
}

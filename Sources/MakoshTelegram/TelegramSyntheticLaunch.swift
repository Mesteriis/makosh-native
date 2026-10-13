#if DEBUG
import Foundation

/// Opt-in QA-bundle gate. The normal product never enables this metadata key.
/// Tool relaunches without explicit fixture arguments must not open normal data.
public func telegramSyntheticLaunchAdmitted(arguments: [String]) -> Bool {
    let supported: Set<String> = [
        "--telegram-group-synthetic-preview", "--telegram-avatar-synthetic-preview",
        "--telegram-server-draft-synthetic-preview", "--telegram-extended-messages-synthetic-preview",
        "--telegram-secret-synthetic-preview", "--telegram-paid-send-synthetic-preview",
        "--telegram-dossier-synthetic-preview", "--telegram-history-read-synthetic-preview",
        "--telegram-peer-profiles-synthetic-preview", "--telegram-peer-appearance-synthetic-preview",
        "--telegram-drafts-synthetic-preview", "--telegram-s3-synthetic-preview", "--telegram-synthetic-preview"
    ]
    let modes = arguments.filter { $0.hasPrefix("--telegram-") && $0.hasSuffix("-synthetic-preview") }
    guard modes.count == 1, let mode = modes.first, supported.contains(mode),
          arguments.filter({ $0 == "--database-config" }).count == 1,
          let index = arguments.firstIndex(of: "--database-config"), arguments.indices.contains(index + 1) else { return false }
    let path = arguments[index + 1]
    return path.hasPrefix("/") && path.utf8.count <= 4096
        && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
}
#endif

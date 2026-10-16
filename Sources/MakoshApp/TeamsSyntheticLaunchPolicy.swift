import Foundation
import MakoshCore
import MakoshTeams

enum TeamsSyntheticLaunchPolicy {
    struct ServiceModes {
        let telegramSynthetic = true, mailSynthetic = true, whatsappSynthetic = true, startOtherWorkers = false
    }
    static let serviceModes = ServiceModes()
    static func admits(arguments: [String], configuration: ContactWorkspaceConfiguration) -> Bool {
        guard arguments.contains("--teams-synthetic-preview"), let index = arguments.firstIndex(of: "--database-config"),
              arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--"),
              let archive = configuration.archiveSchema else { return false }
        guard TeamsQAIsolation.hasPinnedLocalDatabase(configuration) else { return false }
        return [configuration.schema, archive].allSatisfy { schema in
            schema.hasPrefix("qa_teams_") && schema.utf8.count <= 63 &&
            schema.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
        }
    }
}

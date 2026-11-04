import Foundation
import MakoshCore

package enum TeamsSyntheticLaunchPolicy {
    package struct ServiceModes {
        package let telegramSynthetic = true, mailSynthetic = true, whatsappSynthetic = true, startOtherWorkers = false
    }
    package static let serviceModes = ServiceModes()
    package static func admits(arguments: [String], configuration: ContactWorkspaceConfiguration) -> Bool {
        guard arguments.contains("--teams-synthetic-preview"), let index = arguments.firstIndex(of: "--database-config"),
            arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--"),
            let archive = configuration.archiveSchema
        else { return false }
        guard TeamsQAIsolation.hasPinnedLocalDatabase(configuration) else { return false }
        return [configuration.schema, archive].allSatisfy { schema in
            schema.hasPrefix("qa_teams_") && schema.utf8.count <= 63
                && schema.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
        }
    }
}

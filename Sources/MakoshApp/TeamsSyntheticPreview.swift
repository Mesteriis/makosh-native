import SwiftUI
import UserNotifications
import MakoshCore
import MakoshTeams

/// In-memory OS boundary for Teams QA; constructing it never asks the notification daemon for permission.
@MainActor final class TeamsSyntheticNotificationCenter: ApplicationSystemNotificationCenter {
    private var requests: [UNNotificationRequest] = []
    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) { completionHandler(.authorized) }
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void) { completionHandler(true, nil) }
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?) { requests.append(request); completionHandler?(nil) }
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) { completionHandler([]) }
    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) { completionHandler(requests) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { requests.removeAll { identifiers.contains($0.identifier) } }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { requests.removeAll { identifiers.contains($0.identifier) } }
}

#if DEBUG
struct TeamsSyntheticPreview: View {
    @State private var configuration: ContactWorkspaceConfiguration?
    @State private var error: String?
    @StateObject private var model: TeamsWorkspaceModel
    init() {
        let args = CommandLine.arguments
        let storage = args.firstIndex(of: "--storage-config").flatMap { args.indices.contains($0 + 1) && !args[$0 + 1].hasPrefix("--") ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let fixture = args.firstIndex(of: "--teams-qa-fixtures").flatMap { args.indices.contains($0 + 1) && !args[$0 + 1].hasPrefix("--") ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let spool = args.firstIndex(of: "--teams-qa-spool").flatMap { args.indices.contains($0 + 1) && !args[$0 + 1].hasPrefix("--") ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        _model = StateObject(wrappedValue: TeamsWorkspaceModel(worker: TeamsWorker.synthetic(fileRoot: fixture), polling: true, synthetic: true, storageFile: storage, spool: spool))
    }
    var body: some View {
        Group {
            if configuration != nil { WorkspaceView(syntheticTeams: model) }
            else if let error { Text(error).padding(24).frame(minWidth: 650, minHeight: 260).accessibilityIdentifier("teams.qa.configurationRequired") }
            else { ProgressView("Проверка отдельной конфигурации Teams QA…").padding(24) }
        }.task {
            do {
                let args = CommandLine.arguments
                guard let index = args.firstIndex(of: "--database-config"), args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else { throw TeamsFailure.invalidConfiguration }
                let file = URL(fileURLWithPath: args[index + 1])
                let value = try await BackgroundWork.run {
                    let value = try JSONDecoder().decode(ContactWorkspaceConfiguration.self, from: Data(contentsOf: file))
                    guard TeamsSyntheticLaunchPolicy.admits(arguments: args, configuration: value) else { throw TeamsFailure.invalidConfiguration }
                    return value
                }
                configuration = value
            } catch { self.error = "Teams QA требует явный --database-config и отдельные схемы qa_teams_ для приложения и архива. Другие сервисы не запускаются." }
        }
    }
}
#endif

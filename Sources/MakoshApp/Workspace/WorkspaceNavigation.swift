import Combine
import SwiftUI

/// Presentation routing only. Opening settings never constructs a service or a second window.
@MainActor final class WorkspaceNavigation: ObservableObject {
    struct SettingsRequest: Equatable {
        let id = UUID()
        let category: WorkspaceSettingsCategory?
    }
    @Published private(set) var destinationRequest: WorkspaceDestination?
    @Published private(set) var settingsRequest: SettingsRequest?

    func showService(_ destination: WorkspaceDestination) { destinationRequest = destination }

    func openSettings(_ category: WorkspaceSettingsCategory? = nil) {
        settingsRequest = SettingsRequest(category: category)
    }
}

private struct WorkspaceNavigationKey: EnvironmentKey {
    static let defaultValue: WorkspaceNavigation? = nil
}
extension EnvironmentValues {
    var workspaceNavigation: WorkspaceNavigation? {
        get { self[WorkspaceNavigationKey.self] }
        set { self[WorkspaceNavigationKey.self] = newValue }
    }
}

enum WorkspaceSettingsCategory: String, CaseIterable, Identifiable {
    case telegram, mail, whatsapp, teams, meetings, files, tasks, calendar, persons, ai
    var id: String { rawValue }
    var destination: WorkspaceDestination {
        switch self {
        case .telegram: .telegram
        case .mail: .mail
        case .whatsapp: .whatsapp
        case .teams: .teams
        case .meetings: .meetings
        case .files: .files
        case .tasks: .tasks
        case .calendar: .calendar
        case .persons: .persons
        case .ai: .ai
        }
    }
    static func resolve(_ raw: String, allowed: [Self]) -> Self? {
        allowed.first { $0.rawValue == raw } ?? allowed.first
    }
}

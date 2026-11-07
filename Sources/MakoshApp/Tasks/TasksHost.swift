import Combine
import Foundation
import MakoshCore
import MakoshJira
import MakoshTasks
import SwiftUI

/// The Tasks host reaches every view through the environment; views shown
/// without it (tests, isolated previews) offer no task actions.
private struct TasksHostKey: EnvironmentKey {
    static let defaultValue: TasksHost? = nil
}

extension EnvironmentValues {
    var tasksHost: TasksHost? {
        get { self[TasksHostKey.self] }
        set { self[TasksHostKey.self] = newValue }
    }
}

/// One Tasks service and model per process, shared by the workspace window
/// and the settings scene. The workspace hands over the database
/// configuration once its own load has resolved it.
@MainActor final class TasksHost: ObservableObject {
    /// The synthetic-preview flag, re-exported so files that cannot import
    /// `MakoshTasks` (its `Task` would shadow Swift's) still see it.
    nonisolated static let qaFlag = TasksQAIsolation.flag
    private(set) var service: TasksService?
    @Published private(set) var model: TasksWorkspaceModel?
    @Published private(set) var configured = false
    @Published private(set) var failure: String?
    /// Mirrors the model's «show sidebar» for the workspace, which cannot import `MakoshTasks`.
    @Published private(set) var sidebarCollapsed = false
    private var sidebarObservation: AnyCancellable?
    private let adapterFactory: TasksService.AdapterFactory
    private let keychain: JiraKeychainAccess

    init() {
        adapterFactory = { JiraCloudAdapter(credential: $0.credential(token: $1)) }
        keychain = .system
    }

    #if DEBUG
    /// Isolated QA: an in-memory Keychain and a Jira that never touches the network.
    init(synthetic adapter: any JiraAdapter) {
        adapterFactory = { _, _ in adapter }
        keychain = .memory()
    }
    #endif

    /// A task found by its Jira key in a meeting's title or notes.
    struct TimerOffer: Identifiable {
        let id: UUID
        let title: String
    }

    /// «Списать время…» from a meeting card: a draft when the task is clear, else the chooser.
    func logTime(title: String, notes: String, meetingID: UUID, seconds: Int = 1800) {
        guard let model else { return }
        _Concurrency.Task { await model.logMeeting(title: title, notes: notes, meetingID: meetingID, seconds: seconds) }
    }

    /// After «Открыть встречу»: the task to offer a timer for, when exactly one key matches.
    func offerTimer(title: String, notes: String) -> TimerOffer? {
        guard let model, model.timer == nil, let id = model.task(matchingKeysIn: title, notes: notes), let task = model.task(id: id) else {
            return nil
        }
        return TimerOffer(id: id, title: (model.observation(id: id)?.issue.key).map { "\($0) · \(task.title)" } ?? task.title)
    }

    func startTimer(id: UUID) {
        guard let model else { return }
        _Concurrency.Task { await model.startTimer(id: id) }
    }

    /// Opens the store in the application schema and starts polling; safe to call once.
    func start(configuration: ContactWorkspaceConfiguration, seed: ((TaskStore) async throws -> Void)? = nil) async {
        guard !configured else { return }
        configured = true
        let store = TaskStore(connectionString: configuration.connectionString, schema: configuration.schema)
        let service = TasksService(store: store, vault: JiraTokenVault(access: keychain), adapterFactory: adapterFactory)
        self.service = service
        let model = TasksWorkspaceModel(service: service)
        self.model = model
        sidebarObservation = model.$showSidebar.receive(on: DispatchQueue.main).sink { [weak self] shown in
            self?.sidebarCollapsed = !shown
        }
        do {
            try await service.open()
            if let seed { try await seed(store) }
            await model.refresh()
            await service.startPolling()
            _Concurrency.Task { await model.syncNow() }
        } catch {
            failure = "Раздел «Задачи» не открыл хранилище."
        }
    }
}

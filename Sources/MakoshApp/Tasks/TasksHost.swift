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

    /// Opens the store in the application schema and starts polling; safe to call once.
    func start(configuration: ContactWorkspaceConfiguration, seed: ((TaskStore) async throws -> Void)? = nil) async {
        guard !configured else { return }
        configured = true
        let store = TaskStore(connectionString: configuration.connectionString, schema: configuration.schema)
        let service = TasksService(store: store, vault: JiraTokenVault(access: keychain), adapterFactory: adapterFactory)
        self.service = service
        let model = TasksWorkspaceModel(service: service)
        self.model = model
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

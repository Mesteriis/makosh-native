import Combine
import Foundation
import MakoshCore

/// Settings tab state for connections and role assignments. The token is
/// passed straight to the worker's Keychain vault and never published.
@MainActor package final class AISettingsModel: ObservableObject {
    package let worker: AIWorker
    @Published package private(set) var connections: [AIConnection] = []
    @Published package private(set) var roles: [AIRole: AIRoleAssignment] = [:]
    @Published package private(set) var availableModels: [UUID: [String]] = [:]
    @Published package private(set) var testResult: [UUID: Result<Int, AIFailure>] = [:]
    @Published package private(set) var imagesSavedToS3 = true
    @Published package private(set) var failure: AIFailure?

    package init(worker: AIWorker) { self.worker = worker }

    package func start(configuration: PersonWorkspaceConfiguration) async {
        do {
            try await worker.open(configuration: configuration)
            await reload()
        } catch { failure = error as? AIFailure ?? .storage }
    }

    package func reload() async {
        do {
            let snapshot = try await worker.snapshot()
            connections = snapshot.connections
            roles = Dictionary(snapshot.roles.map { ($0.role, $0) }, uniquingKeysWith: { $1 })
            imagesSavedToS3 = snapshot.imagesSavedToS3
        } catch { failure = error as? AIFailure ?? .storage }
    }

    /// A nil token keeps the stored one; an empty token removes it.
    package func save(_ connection: AIConnection, token: String?) async {
        await perform { try await self.worker.save(connection, token: token) }
    }

    package func remove(_ id: UUID) async {
        await perform { try await self.worker.removeConnection(id) }
        availableModels[id] = nil
        testResult[id] = nil
    }

    package func test(_ id: UUID) async {
        do {
            let models = try await worker.testConnection(id)
            availableModels[id] = models
            testResult[id] = .success(models.count)
        } catch {
            testResult[id] = .failure(error as? AIFailure ?? .network)
        }
    }

    package func assign(_ role: AIRole, connectionID: UUID?, model: String, contextTokens: Int? = nil) async {
        let assignment = connectionID.map {
            AIRoleAssignment(
                role: role, connectionID: $0, model: model.trimmingCharacters(in: .whitespaces),
                contextTokens: contextTokens ?? roles[role]?.contextTokens)
        }
        await perform { try await self.worker.assign(assignment, role: role) }
    }

    /// The chat model's context window; nil or zero returns to the default.
    package func setContextTokens(_ value: Int?, role: AIRole) async {
        guard let current = roles[role] else { return }
        let assignment = AIRoleAssignment(
            role: role, connectionID: current.connectionID, model: current.model, contextTokens: (value ?? 0) > 0 ? value : nil)
        await perform { try await self.worker.assign(assignment, role: role) }
    }

    package func setImagesSavedToS3(_ value: Bool) async {
        await perform { try await self.worker.setImagesSavedToS3(value) }
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        failure = nil
        do { try await operation() } catch { failure = error as? AIFailure ?? .storage }
        await reload()
    }
}

import Foundation
import MakoshCore

public struct AIWorkspaceSnapshot: Sendable, Equatable {
    public let connections: [AIConnection]
    public let roles: [AIRoleAssignment]
    public let conversations: [AIConversation]
    public let imagesSavedToS3: Bool
}

public enum AIConversationEvent: Sendable, Equatable { case updated(AIMessage), finished(UUID) }

/// Owns AI network, storage and crypto work off the main actor. One
/// generation runs per conversation; deleting a conversation cancels it and
/// bumps its epoch so late deltas are never written back.
public actor AIWorker {
    private let repository: AIRepository
    private let client: any AIServing
    private let vault: any AITokenStoring
    private let images: AIImageStore?
    private let now: @Sendable () -> Date
    private var active: [UUID: Task<Void, Never>] = [:]
    private var epochs: [UUID: UInt64] = [:]

    public init(
        repository: AIRepository = .init(), client: any AIServing = AIClient(), vault: any AITokenStoring = AITokenVault(),
        images: AIImageStore? = nil, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.client = client
        self.vault = vault
        self.images = images
        self.now = now
    }

    public func open(configuration: ContactWorkspaceConfiguration) async throws { try await repository.open(configuration: configuration) }

    public func close() async {
        let tasks = Array(active.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        await repository.close()
    }

    public func snapshot() async throws -> AIWorkspaceSnapshot {
        AIWorkspaceSnapshot(
            connections: try await repository.connections(), roles: try await repository.roles(),
            conversations: try await repository.conversations(), imagesSavedToS3: try await repository.imagesSavedToS3())
    }

    // MARK: Connections and roles

    /// A nil token keeps the stored one; an empty token removes it.
    public func save(_ connection: AIConnection, token: String?) async throws {
        try await repository.save(connection.validated())
        if let token { try await vault.save(token, connectionID: connection.id) }
    }
    public func removeConnection(_ id: UUID) async throws {
        try await repository.removeConnection(id)
        try await vault.remove(connectionID: id)
    }
    public func testConnection(_ id: UUID) async throws -> [String] {
        guard let connection = try await repository.connections().first(where: { $0.id == id }) else { throw AIFailure.invalidConnection }
        return try await client.models(connection: connection, token: vault.load(connectionID: id))
    }
    public func assign(_ assignment: AIRoleAssignment?, role: AIRole) async throws { try await repository.assign(assignment, role: role) }
    public func setImagesSavedToS3(_ value: Bool) async throws { try await repository.setImagesSavedToS3(value) }

    private func resolve(_ role: AIRole) async throws -> (AIConnection, String?, String) {
        guard let assignment = try await repository.roles().first(where: { $0.role == role }),
            let connection = try await repository.connections().first(where: { $0.id == assignment.connectionID })
        else { throw AIFailure.roleUnassigned(role) }
        return (connection, try await vault.load(connectionID: connection.id), assignment.model)
    }

    // MARK: Conversations

    public func createConversation() async throws -> AIConversation {
        let conversation = AIConversation(title: "", createdAt: now(), updatedAt: now())
        try await repository.save(conversation)
        return conversation
    }
    public func messages(_ conversationID: UUID) async throws -> [AIMessage] {
        try await repository.messages(conversationID: conversationID)
    }
    public func isStreaming(conversationID: UUID) -> Bool { active[conversationID] != nil }

    public func deleteConversation(_ id: UUID) async throws {
        epochs[id, default: 0] += 1
        if let task = active[id] {
            task.cancel()
            await task.value
        }
        let references = try await repository.deleteConversation(id)
        for reference in references { try await images?.delete(reference, conversationID: id) }
    }

    public func selectVersion(_ index: Int, messageID: UUID, conversationID: UUID) async throws {
        guard var message = try await repository.messages(conversationID: conversationID).first(where: { $0.id == messageID }),
            message.versions.indices.contains(index)
        else { throw AIFailure.invalidConfiguration }
        message.selectedVersion = index
        try await repository.save(message)
    }

    public func stop(conversationID: UUID) { active[conversationID]?.cancel() }

    public func send(_ text: String, conversationID: UUID, editing: UUID?) -> AsyncThrowingStream<AIConversationEvent, Error> {
        generate(conversationID: conversationID) { worker in
            try await worker.prepareSend(text, conversationID: conversationID, editing: editing)
        }
    }

    public func regenerate(_ assistantMessageID: UUID, conversationID: UUID) -> AsyncThrowingStream<AIConversationEvent, Error> {
        generate(conversationID: conversationID) { worker in
            try await worker.prepareRegenerate(assistantMessageID, conversationID: conversationID)
        }
    }

    /// Returns the assistant message to fill and the turns that precede it.
    private typealias Preparation = (message: AIMessage, turns: [AIChatTurn], model: String, connection: AIConnection, token: String?)

    private func generate(
        conversationID: UUID, prepare: @escaping @Sendable (isolated AIWorker) async throws -> Preparation
    ) -> AsyncThrowingStream<AIConversationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AIConversationEvent.self)
        guard active[conversationID] == nil else {
            continuation.finish(throwing: AIFailure.busy)
            return stream
        }
        let epoch = epochs[conversationID, default: 0]
        let task = Task {
            do {
                let preparation = try await prepare(self)
                try await self.run(preparation, conversationID: conversationID, epoch: epoch, continuation: continuation)
            } catch {
                continuation.finish(throwing: error)
            }
            self.finish(conversationID)
        }
        active[conversationID] = task
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }

    private func finish(_ conversationID: UUID) { active[conversationID] = nil }

    private func prepareSend(_ text: String, conversationID: UUID, editing: UUID?) async throws -> Preparation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIFailure.invalidConfiguration }
        let (connection, token, model) = try await resolve(.chat)
        let path = AIMessage.path(try await repository.messages(conversationID: conversationID))
        let version = AIMessageVersion(text: trimmed, state: .complete, model: nil, createdAt: now())
        var question: AIMessage
        var history: [AIMessage]
        if let editing {
            guard let index = path.firstIndex(where: { $0.id == editing && $0.author == .user }) else {
                throw AIFailure.invalidConfiguration
            }
            question = path[index]
            question.versions.append(version)
            question.selectedVersion = question.versions.count - 1
            history = Array(path[..<index])
        } else {
            question = AIMessage(
                conversationID: conversationID, parentID: path.last?.id, parentVersionID: path.last?.current?.id, author: .user,
                versions: [version])
            history = path
        }
        try await repository.save(question)
        history.append(question)
        try await touch(conversationID, title: trimmed)
        let answer = AIMessage(
            conversationID: conversationID, parentID: question.id, parentVersionID: version.id, author: .assistant,
            versions: [.init(text: "", state: .streaming, model: model, createdAt: now())])
        try await repository.save(answer)
        return (answer, Self.turns(history), model, connection, token)
    }

    private func prepareRegenerate(_ messageID: UUID, conversationID: UUID) async throws -> Preparation {
        let (connection, token, model) = try await resolve(.chat)
        let path = AIMessage.path(try await repository.messages(conversationID: conversationID))
        guard let index = path.firstIndex(where: { $0.id == messageID && $0.author == .assistant }) else {
            throw AIFailure.invalidConfiguration
        }
        var answer = path[index]
        answer.versions.append(.init(text: "", state: .streaming, model: model, createdAt: now()))
        answer.selectedVersion = answer.versions.count - 1
        try await repository.save(answer)
        try await touch(conversationID, title: nil)
        return (answer, Self.turns(Array(path[..<index])), model, connection, token)
    }

    private static func turns(_ path: [AIMessage]) -> [AIChatTurn] {
        path.compactMap { message in
            guard let version = message.current, version.image == nil, version.state != .failed, !version.text.isEmpty else { return nil }
            return AIChatTurn(author: message.author, text: version.text)
        }
    }

    private func touch(_ conversationID: UUID, title: String?) async throws {
        guard var conversation = try await repository.conversations().first(where: { $0.id == conversationID }) else {
            throw AIFailure.invalidConfiguration
        }
        conversation.updatedAt = now()
        if conversation.title.isEmpty, let title { conversation.title = String(title.prefix(60)) }
        try await repository.save(conversation)
    }

    private func run(
        _ preparation: Preparation, conversationID: UUID, epoch: UInt64,
        continuation: AsyncThrowingStream<AIConversationEvent, Error>.Continuation
    ) async throws {
        var message = preparation.message
        let index = message.selectedVersion
        var lastSave = ContinuousClock.now
        func current() -> Bool { epochs[conversationID, default: 0] == epoch }
        func persist(_ value: AIMessage) async throws {
            guard current() else { return }
            try await repository.save(value)
            continuation.yield(.updated(value))
        }
        continuation.yield(.updated(message))
        var completed = false
        var failure: Error?
        do {
            let stream = client.chat(
                connection: preparation.connection, token: preparation.token, model: preparation.model, turns: preparation.turns)
            for try await event in stream {
                guard current() else { break }
                switch event {
                case .delta(let text):
                    message.versions[index].text += text
                    if ContinuousClock.now - lastSave >= .milliseconds(500) {
                        lastSave = ContinuousClock.now
                        message.versions[index].state = .streaming
                        try await persist(message)
                    } else {
                        continuation.yield(.updated(message))
                    }
                case .done: completed = true
                }
                if completed { break }
            }
        } catch { failure = error }
        guard current() else {
            continuation.finish()
            return
        }
        if completed {
            message.versions[index].state = .complete
            try await persist(message)
        } else if let failure, failure as? AIFailure != .network, failure as? AIFailure != .cancelled {
            message.versions[index].state = .failed
            try await persist(message)
            continuation.finish(throwing: failure)
            return
        } else {
            message.versions[index].state = .interrupted
            try await persist(message)
            if let failure, failure as? AIFailure == .network {
                continuation.finish(throwing: failure)
                return
            }
        }
        continuation.yield(.finished(conversationID))
        continuation.finish()
    }

    // MARK: Images and voice

    public func generateImage(prompt: String, conversationID: UUID) async throws -> AIMessage {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIFailure.invalidConfiguration }
        guard let images else { throw AIFailure.storage }
        let (connection, token, model) = try await resolve(.images)
        let png = try await client.image(connection: connection, token: token, model: model, prompt: trimmed)
        let reference = try await images.store(
            png, conversationID: conversationID, toS3: repository.imagesSavedToS3())
        let path = AIMessage.path(try await repository.messages(conversationID: conversationID))
        let questionVersion = AIMessageVersion(text: trimmed, state: .complete, model: nil, createdAt: now())
        let question = AIMessage(
            conversationID: conversationID, parentID: path.last?.id, parentVersionID: path.last?.current?.id, author: .user,
            versions: [questionVersion])
        let answer = AIMessage(
            conversationID: conversationID, parentID: question.id, parentVersionID: questionVersion.id, author: .assistant,
            versions: [.init(text: "", state: .complete, model: model, createdAt: now(), image: reference)])
        try await repository.save(question)
        try await repository.save(answer)
        try await touch(conversationID, title: trimmed)
        return answer
    }

    public func image(_ reference: AIImageReference, conversationID: UUID) async throws -> Data {
        guard let images else { throw AIFailure.storage }
        return try await images.load(reference, conversationID: conversationID)
    }

    public func transcribe(_ audio: URL) async throws -> String {
        let (connection, token, model) = try await resolve(.transcription)
        return try await client.transcribe(connection: connection, token: token, model: model, audio: audio)
    }

    public func speech(_ text: String) async throws -> Data {
        let (connection, token, model) = try await resolve(.speech)
        return try await client.speech(connection: connection, token: token, model: model, text: text)
    }
}

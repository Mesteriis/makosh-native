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
    /// Conversations whose deletion has started; new work on them is refused.
    private var deleted: Set<UUID> = []
    private var retrievalVectors: AIVectorStore?
    private var retrievalAccess: (any AIAccessProvider)?

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
        let validated = try connection.validated()
        let previous = try await repository.connections().first { $0.id == connection.id }
        try await repository.save(validated)
        if let token {
            try await vault.save(token, connectionID: connection.id)
        } else if let previous, Self.origin(previous.baseURL) != Self.origin(validated.baseURL) {
            // A stored secret never follows a connection to another origin.
            try await vault.remove(connectionID: connection.id)
        }
    }
    private static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\((url.host ?? "").lowercased()):\(port)"
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
    /// Enables answering from permitted Makosh data; attached after the indexer exists.
    public func attachRetrieval(vectors: AIVectorStore, access: any AIAccessProvider) {
        retrievalVectors = vectors
        retrievalAccess = access
    }

    public func setSearchMyData(_ enabled: Bool, conversationID: UUID) async throws {
        guard var conversation = try await repository.conversations().first(where: { $0.id == conversationID }) else {
            throw AIFailure.invalidConfiguration
        }
        conversation.searchMyData = enabled
        try await repository.save(conversation)
    }

    /// Permitted chunks for a question. Every match is checked against a
    /// fresh access snapshot, so a chunk closed after indexing never leaves.
    /// Any failure means a plain answer, not an error.
    private func retrieve(_ question: String, conversationID: UUID) async -> (turn: AIChatTurn?, sources: [AISourceReference]) {
        guard let vectors = retrievalVectors, let access = retrievalAccess else { return (nil, []) }
        do {
            guard try await repository.conversations().first(where: { $0.id == conversationID })?.searchMyData != false,
                let generation = try await vectors.activeGeneration()
            else { return (nil, []) }
            let role = try await embeddingRole()
            guard role.connectionID == generation.connectionID, role.model == generation.model else { return (nil, []) }
            let query = try await embed([question])
            guard let vector = query.vectors.first else { return (nil, []) }
            let matches = try await vectors.search(
                vector, generation: generation.id, limit: AIRetrieval.limit, maxDistance: AIRetrieval.maxDistance)
            let snapshot = try await access.snapshot()
            let permitted = matches.map(\.chunk).filter { snapshot.admits($0) }
            guard !permitted.isEmpty else { return (nil, []) }
            let context = AIRetrieval.context(permitted)
            return (context.turn, context.sources)
        } catch { return (nil, []) }
    }

    public func messages(_ conversationID: UUID) async throws -> [AIMessage] {
        try await repository.messages(conversationID: conversationID)
    }
    public func isStreaming(conversationID: UUID) -> Bool { active[conversationID] != nil }

    public func deleteConversation(_ id: UUID) async throws {
        deleted.insert(id)
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
        guard active[conversationID] == nil, !deleted.contains(conversationID) else {
            continuation.finish(throwing: deleted.contains(conversationID) ? AIFailure.invalidConfiguration : AIFailure.busy)
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
        let retrieved = await retrieve(trimmed, conversationID: conversationID)
        let answer = AIMessage(
            conversationID: conversationID, parentID: question.id, parentVersionID: version.id, author: .assistant,
            versions: [.init(text: "", state: .streaming, model: model, createdAt: now(), sources: retrieved.sources)])
        try await repository.save(answer)
        return (answer, (retrieved.turn.map { [$0] } ?? []) + Self.turns(history), model, connection, token)
    }

    private func prepareRegenerate(_ messageID: UUID, conversationID: UUID) async throws -> Preparation {
        let (connection, token, model) = try await resolve(.chat)
        let path = AIMessage.path(try await repository.messages(conversationID: conversationID))
        guard let index = path.firstIndex(where: { $0.id == messageID && $0.author == .assistant }) else {
            throw AIFailure.invalidConfiguration
        }
        var answer = path[index]
        let question = path[..<index].last { $0.author == .user }?.current?.text ?? ""
        let retrieved = question.isEmpty ? (turn: nil, sources: []) : await retrieve(question, conversationID: conversationID)
        answer.versions.append(.init(text: "", state: .streaming, model: model, createdAt: now(), sources: retrieved.sources))
        answer.selectedVersion = answer.versions.count - 1
        try await repository.save(answer)
        try await touch(conversationID, title: nil)
        return (answer, (retrieved.turn.map { [$0] } ?? []) + Self.turns(Array(path[..<index])), model, connection, token)
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

    /// Runs as the conversation's one active job, so deletion cancels and
    /// awaits it like a chat stream.
    public func generateImage(prompt: String, conversationID: UUID) async throws -> AIMessage {
        guard !deleted.contains(conversationID) else { throw AIFailure.invalidConfiguration }
        guard active[conversationID] == nil else { throw AIFailure.busy }
        let epoch = epochs[conversationID, default: 0]
        let (results, continuation) = AsyncThrowingStream.makeStream(of: AIMessage.self)
        active[conversationID] = Task {
            do {
                continuation.yield(try await self.produceImage(prompt: prompt, conversationID: conversationID, epoch: epoch))
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
            self.finish(conversationID)
        }
        for try await message in results { return message }
        throw AIFailure.cancelled
    }

    private func produceImage(prompt: String, conversationID: UUID, epoch: UInt64) async throws -> AIMessage {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIFailure.invalidConfiguration }
        guard let images else { throw AIFailure.storage }
        let (connection, token, model) = try await resolve(.images)
        let png = try await client.image(connection: connection, token: token, model: model, prompt: trimmed)
        let reference = try await images.store(
            png, conversationID: conversationID, toS3: repository.imagesSavedToS3())
        guard epochs[conversationID, default: 0] == epoch, !Task.isCancelled else {
            try? await images.delete(reference, conversationID: conversationID)
            throw AIFailure.cancelled
        }
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

    /// The connection and model assigned to the embeddings role.
    public func embeddingRole() async throws -> (connectionID: UUID, model: String) {
        let (connection, _, model) = try await resolve(.embeddings)
        return (connection.id, model)
    }

    public func embed(_ inputs: [String]) async throws -> (connectionID: UUID, model: String, vectors: [[Float]]) {
        let (connection, token, model) = try await resolve(.embeddings)
        let vectors = try await client.embeddings(connection: connection, token: token, model: model, inputs: inputs)
        guard vectors.count == inputs.count else { throw AIFailure.malformedResponse }
        return (connection.id, model, vectors)
    }

    func indexState() async throws -> AIIndexState? { try await repository.setting(AIIndexState.self, key: "indexState") }
    func saveIndexState(_ state: AIIndexState) async throws { try await repository.setSetting(state, key: "indexState") }

    public func transcribe(_ audio: URL) async throws -> String {
        let (connection, token, model) = try await resolve(.transcription)
        return try await client.transcribe(connection: connection, token: token, model: model, audio: audio)
    }

    public func speech(_ text: String) async throws -> Data {
        let (connection, token, model) = try await resolve(.speech)
        return try await client.speech(connection: connection, token: token, model: model, text: text)
    }
}

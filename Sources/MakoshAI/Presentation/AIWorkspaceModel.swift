import Combine
import Foundation
import MakoshCore

/// Window-scoped conductor for AI conversations. Network, storage and crypto
/// stay in `AIWorker`; every published update is checked against the
/// selection captured before the await.
@MainActor package final class AIWorkspaceModel: ObservableObject {
    package let worker: AIWorker
    @Published package private(set) var conversations: [AIConversation] = []
    @Published package private(set) var selectedConversationID: UUID?
    @Published package private(set) var path: [AIMessage] = []
    @Published package private(set) var isStreaming = false
    @Published package private(set) var failure: AIFailure?
    @Published package private(set) var roles: [AIRole: AIRoleAssignment] = [:]
    @Published package private(set) var ready = false
    private var selection: UInt64 = 0
    private var subscriptions: Set<AnyCancellable> = []

    package init(worker: AIWorker) { self.worker = worker }

    /// Keeps role-dependent actions current when the settings scene changes roles.
    package func follow(_ settings: AISettingsModel) {
        settings.$roles.dropFirst().sink { [weak self] roles in self?.roles = roles }.store(in: &subscriptions)
    }

    package func start(configuration: ContactWorkspaceConfiguration) async {
        guard !ready else { return }
        do {
            try await worker.open(configuration: configuration)
            ready = true
            await reload()
        } catch { failure = error as? AIFailure ?? .storage }
    }

    package func reload() async {
        do {
            let snapshot = try await worker.snapshot()
            conversations = snapshot.conversations
            roles = Dictionary(snapshot.roles.map { ($0.role, $0) }, uniquingKeysWith: { $1 })
        } catch { failure = error as? AIFailure ?? .storage }
    }

    package func select(_ id: UUID?) async {
        selection &+= 1
        let token = selection
        selectedConversationID = id
        path = []
        isStreaming = false
        failure = nil
        guard let id else { return }
        await refresh(id, token: token)
        if selection == token { isStreaming = await worker.isStreaming(conversationID: id) }
    }

    package func newConversation() async {
        do {
            let conversation = try await worker.createConversation()
            await reload()
            await select(conversation.id)
        } catch { failure = error as? AIFailure ?? .storage }
    }

    package func delete(_ id: UUID) async {
        do {
            try await worker.deleteConversation(id)
            if selectedConversationID == id { await select(nil) }
            await reload()
        } catch { failure = error as? AIFailure ?? .storage }
    }

    package func send(_ text: String) async {
        guard let id = selectedConversationID else { return }
        await consume(await worker.send(text, conversationID: id, editing: nil), conversation: id)
    }

    package func edit(_ messageID: UUID, text: String) async {
        guard let id = selectedConversationID else { return }
        await consume(await worker.send(text, conversationID: id, editing: messageID), conversation: id)
    }

    package func regenerate(_ messageID: UUID) async {
        guard let id = selectedConversationID else { return }
        await consume(await worker.regenerate(messageID, conversationID: id), conversation: id)
    }

    package func selectVersion(_ index: Int, of messageID: UUID) async {
        guard let id = selectedConversationID else { return }
        let token = selection
        do {
            try await worker.selectVersion(index, messageID: messageID, conversationID: id)
            await refresh(id, token: token)
        } catch { if selection == token { failure = error as? AIFailure ?? .storage } }
    }

    package func stop() {
        guard let id = selectedConversationID else { return }
        Task { await worker.stop(conversationID: id) }
    }

    package func generateImage(_ prompt: String) async {
        guard let id = selectedConversationID else { return }
        let token = selection
        do {
            _ = try await worker.generateImage(prompt: prompt, conversationID: id)
            await refresh(id, token: token)
            await reload()
        } catch { if selection == token { failure = error as? AIFailure ?? .storage } }
    }

    package func image(_ reference: AIImageReference) async -> Data? {
        guard let id = selectedConversationID else { return nil }
        return try? await worker.image(reference, conversationID: id)
    }

    package func transcribe(_ audio: URL) async -> String? {
        do { return try await worker.transcribe(audio) } catch {
            failure = error as? AIFailure ?? .storage
            return nil
        }
    }

    package func speak(_ messageID: UUID) async -> Data? {
        guard let text = path.first(where: { $0.id == messageID })?.current?.text, !text.isEmpty else { return nil }
        do { return try await worker.speech(text) } catch {
            failure = error as? AIFailure ?? .storage
            return nil
        }
    }

    package func dismissFailure() { failure = nil }

    /// Publishes while the stream's conversation is selected, including after
    /// the user leaves and comes back to it mid-answer.
    private func consume(_ stream: AsyncThrowingStream<AIConversationEvent, Error>, conversation id: UUID) async {
        failure = nil
        isStreaming = true
        do {
            for try await event in stream {
                guard selectedConversationID == id else { continue }
                if case .updated(let message) = event {
                    if let index = path.firstIndex(where: { $0.id == message.id }) {
                        path[index] = message
                    } else {
                        await refresh(id, token: selection)
                    }
                }
            }
        } catch {
            if selectedConversationID == id { failure = error as? AIFailure ?? .network }
        }
        await reload()
        guard selectedConversationID == id else { return }
        isStreaming = false
        await refresh(id, token: selection)
    }

    private func refresh(_ id: UUID, token: UInt64) async {
        do {
            let messages = try await worker.messages(id)
            guard selection == token else { return }
            path = AIMessage.path(messages)
        } catch { if selection == token { failure = error as? AIFailure ?? .storage } }
    }
}

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
    /// The chat whose panel this model shows; nil in the AI section.
    @Published package private(set) var anchor: AIContextCard?
    /// Material of each attached card, by card id, and cards that cannot be sent.
    @Published package private(set) var previews: [String: AIContextMaterial] = [:]
    @Published package private(set) var previewFailures: [String: AIFailure] = [:]
    /// Text extraction under way for a file card, by card id.
    @Published package private(set) var extraction: [String: AIExtractionProgress] = [:]
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    @Published package var filter: AIConversationFilter = .all
    private var selection: UInt64 = 0
    private var anchoring: UInt64 = 0
    private var subscriptions: Set<AnyCancellable> = []

    package init(worker: AIWorker) { self.worker = worker }

    /// Keeps role-dependent actions current when the settings scene changes roles.
    package func follow(_ settings: AISettingsModel) {
        settings.$roles.dropFirst().sink { [weak self] roles in self?.roles = roles }.store(in: &subscriptions)
    }

    package func start(configuration: PersonWorkspaceConfiguration) async {
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
        previews = [:]
        previewFailures = [:]
        guard let id else { return }
        await refresh(id, token: token)
        if selection == token { isStreaming = await worker.isStreaming(conversationID: id) }
        // Cards show what will be sent wherever the conversation is open.
        if selection == token { await refreshPreviews(token: anchoring) }
    }

    package var selectedConversation: AIConversation? { conversations.first { $0.id == selectedConversationID } }
    package var cards: [AIContextCard] { selectedConversation?.cards ?? [] }

    /// In a chat's panel only that chat's conversations; in the AI section by filter.
    package var visibleConversations: [AIConversation] {
        if let anchor { return conversations.filter { $0.anchor?.id == anchor.id } }
        switch filter {
        case .all: return conversations
        case .unanchored: return conversations.filter { $0.anchor == nil }
        case .anchored: return conversations.filter { $0.anchor != nil }
        }
    }

    /// Shows a chat's panel: its latest conversation, or a new one with the
    /// chat attached. A later call wins over an earlier one still loading.
    package func open(anchor card: AIContextCard) async {
        anchoring &+= 1
        let token = anchoring
        anchor = card
        previews = [:]
        previewFailures = [:]
        do {
            let existing = try await worker.conversations(anchoredTo: card).max { $0.updatedAt < $1.updatedAt }
            guard anchoring == token else { return }
            let conversation: AIConversation
            if let existing {
                conversation = existing
            } else {
                conversation = try await worker.createConversation(anchor: card)
            }
            guard anchoring == token else { return }
            await reload()
            guard anchoring == token else { return }
            await select(conversation.id)
            await refreshPreviews(token: token)
        } catch { if anchoring == token { failure = error as? AIFailure ?? .storage } }
    }

    /// Back to the AI section's view of all conversations.
    package func leaveAnchor() async {
        anchoring &+= 1
        anchor = nil
        previews = [:]
        previewFailures = [:]
    }

    package func add(_ card: AIContextCard) async {
        guard !cards.contains(where: { $0.id == card.id }) else { return }
        await changeCards { worker, id in try await worker.addCard(card, conversationID: id) }
    }

    /// Told after a card is removed, so caches of its text can go.
    package var cardRemoved: (@MainActor (String) -> Void)?

    package func remove(_ cardID: String) async {
        extraction[cardID] = nil
        await changeCards { worker, id in try await worker.removeCard(cardID, conversationID: id) }
        cardRemoved?(cardID)
    }

    /// Called by the context bridge while a file card is being read; nil clears.
    package func reportExtraction(cardID: String, progress: AIExtractionProgress?) {
        if let progress, cards.contains(where: { $0.id == cardID }) { extraction[cardID] = progress } else { extraction[cardID] = nil }
    }

    package func setRange(_ range: AIContextRange, for cardID: String) async {
        guard let card = cards.first(where: { $0.id == cardID }), case .chat(let service, let accountID, let chatID, let title, _) = card
        else { return }
        let changed = AIContextCard.chat(service: service, accountID: accountID, chatID: chatID, title: title, range: range)
        await changeCards { worker, id in try await worker.addCard(changed, conversationID: id) }
    }

    /// A file card's page range; nil means the whole file. The card keeps its id and place.
    package func setPages(_ pages: ClosedRange<Int>?, for cardID: String) async {
        guard let card = cards.first(where: { $0.id == cardID }), case .file(let source, let title, _) = card else { return }
        let changed = AIContextCard.file(source: source, title: title, pages: pages)
        await changeCards { worker, id in try await worker.addCard(changed, conversationID: id) }
    }

    /// Each change is applied by the worker to the stored list, so quick
    /// changes from the panel and the AI section never overwrite each other.
    private func changeCards(_ change: @Sendable (AIWorker, UUID) async throws -> Void) async {
        guard let id = selectedConversationID else { return }
        let token = anchoring
        do {
            try await change(worker, id)
            await reload()
            await refreshPreviews(token: token)
        } catch { failure = error as? AIFailure ?? .storage }
    }

    /// Previews are read in their own task; a newer refresh or a removed card
    /// cancels the old one, and a late result never lands.
    private func refreshPreviews(token: UInt64) async {
        previewGeneration += 1
        let generation = previewGeneration
        previewTask?.cancel()
        let cards = self.cards, worker = self.worker
        extraction = extraction.filter { entry in cards.contains { $0.id == entry.key } }
        let task = Task { [weak self] in
            var materials: [String: AIContextMaterial] = [:], failures: [String: AIFailure] = [:]
            for card in cards {
                do { materials[card.id] = try await worker.preview(card: card) } catch {
                    failures[card.id] = error as? AIFailure ?? .storage
                }
                guard !Task.isCancelled, let self, self.previewGeneration == generation, self.anchoring == token else { return }
            }
            guard let self, self.previewGeneration == generation, self.anchoring == token else { return }
            self.previews = materials
            self.previewFailures = failures
            self.extraction = [:]
        }
        previewTask = task
        await task.value
    }

    package func newConversation() async {
        if let anchor {
            do {
                let conversation = try await worker.createConversation(anchor: anchor)
                await reload()
                await select(conversation.id)
                await refreshPreviews(token: anchoring)
            } catch { failure = error as? AIFailure ?? .storage }
            return
        }
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

    /// Whether the selected conversation searches permitted Makosh data.
    package var searchMyData: Bool { conversations.first { $0.id == selectedConversationID }?.searchMyData ?? true }

    package func setSearchMyData(_ enabled: Bool) async {
        guard let id = selectedConversationID else { return }
        do {
            try await worker.setSearchMyData(enabled, conversationID: id)
            await reload()
        } catch { failure = error as? AIFailure ?? .storage }
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

/// Which conversations the AI section lists.
package enum AIConversationFilter: CaseIterable, Sendable { case all, unanchored, anchored }

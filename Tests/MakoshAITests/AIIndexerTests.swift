import MakoshCore
import XCTest
@testable import MakoshAI

actor AIFakeIndexSource: AIIndexSource {
    nonisolated let name: String
    private var stored: [AIIndexItem] = []
    init(name: String = "fake") { self.name = name }
    func add(_ items: [AIIndexItem]) { stored.append(contentsOf: items) }
    func items(after sequence: Int64, limit: Int) -> [AIIndexItem] {
        Array(stored.filter { $0.sequence > sequence }.sorted { $0.sequence < $1.sequence }.prefix(limit))
    }
    /// Like real sources: the latest state of each message, without deleted ones.
    func items(in scope: AIAccessScope, after sequence: Int64, limit: Int) -> [AIIndexItem] {
        let latest = Dictionary(grouping: stored.filter { $0.scope == scope }, by: \.identity).compactMap {
            $0.value.max { $0.sequence < $1.sequence }
        }
        return Array(latest.filter { !$0.removed && $0.sequence > sequence }.sorted { $0.sequence < $1.sequence }.prefix(limit))
    }
    func edit(messageID: String, sequence: Int64, text: String) {
        guard let original = stored.first(where: { $0.identity.messageID == messageID }) else { return }
        stored.append(
            AIIndexItem(
                sequence: sequence, identity: original.identity, scope: original.scope, author: original.author,
                isOutgoing: original.isOutgoing,
                date: original.date, title: original.title, text: text, removed: false))
    }
}

actor AIFakeAccess: AIAccessProvider {
    private var enabled: Set<AIAccessScope> = []
    private var contacts: [ServiceIdentity: AIContactAccess] = [:]
    func snapshot() -> AIAccessSnapshot { AIAccessSnapshot(enabledScopes: enabled, contactAccess: contacts) }
    func setScope(_ scope: AIAccessScope, enabled value: Bool) {
        if value { enabled.insert(scope) } else { enabled.remove(scope) }
    }
    func setContact(_ identity: ServiceIdentity, _ access: AIContactAccess) { contacts[identity] = access }
}

final class AIIndexerTests: XCTestCase {
    private var database: AITestDatabase!
    private var service: AIFakeService!
    private var worker: AIWorker!
    private var vectors: AIVectorStore!
    private var source: AIFakeIndexSource!
    private var access: AIFakeAccess!
    private let connection = AIConnection(name: "Synthetic", baseURL: URL(string: "http://127.0.0.1:9/v1")!)
    private let chat = AIAccessScope.conversation(service: "telegram", accountID: "acc", conversationID: "c")

    override func setUp() async throws {
        database = try AITestDatabase()
        service = AIFakeService()
        worker = AIWorker(repository: AIRepository(keyProvider: aiTestKey), client: service, vault: AIFakeVault())
        try await worker.open(configuration: database.configuration)
        try await worker.save(connection, token: nil)
        try await worker.assign(.init(role: .embeddings, connectionID: connection.id, model: "e1"), role: .embeddings)
        vectors = AIVectorStore(keyProvider: aiTestKey)
        try await vectors.open(configuration: database.configuration)
        source = AIFakeIndexSource()
        access = AIFakeAccess()
    }
    override func tearDown() async throws {
        await vectors?.close()
        await worker?.close()
        try database?.cleanup()
    }

    private func indexer() -> AIIndexer {
        AIIndexer(worker: worker, vectors: vectors, sources: [source], access: access, pace: .zero)
    }
    private func indexedTexts() async throws -> [String] {
        guard let generation = try await vectors.activeGeneration() else { return [] }
        return try await vectors.chunks(generation: generation.id).map(\.text).sorted()
    }
    private func embeddedText() -> String { service.embedded.flatMap { $0 }.joined(separator: "\n") }

    func testNothingSentWithoutEnabledScope() async throws {
        await source.add([aiItem(1, text: "private")])
        let status = try await indexer().runOnce()
        XCTAssertTrue(service.embedded.isEmpty)
        XCTAssertEqual(status.indexed, 0)
    }

    func testEnableBackfillsHistory() async throws {
        await source.add([aiItem(1, text: "old history"), aiItem(2, text: "more history")])
        let indexer = indexer()
        _ = try await indexer.runOnce()
        await access.setScope(chat, enabled: true)
        let status = try await indexer.runOnce()
        let texts = try await indexedTexts()
        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts[0].contains("old history") && texts[0].contains("more history"))
        XCTAssertEqual(status.indexed, 1)
        XCTAssertEqual(status.pending, 0)
    }

    func testDisablePurgesScope() async throws {
        await source.add([aiItem(1, text: "temporary")])
        await access.setScope(chat, enabled: true)
        let indexer = indexer()
        _ = try await indexer.runOnce()
        await access.setScope(chat, enabled: false)
        _ = try await indexer.runOnce()
        let texts = try await indexedTexts()
        XCTAssertTrue(texts.isEmpty)
    }

    func testContactForbidPurgesAuthorChunks() async throws {
        await source.add([aiItem(1, text: "kept words"), aiItem(2, text: "banned words", author: "bad")])
        await access.setScope(chat, enabled: true)
        let indexer = indexer()
        _ = try await indexer.runOnce()
        var texts = try await indexedTexts()
        XCTAssertTrue(texts.joined().contains("banned words"))
        await access.setContact(ServiceIdentity(service: "telegram", accountID: "acc", externalID: "bad"), .forbidden)
        _ = try await indexer.runOnce()
        texts = try await indexedTexts()
        XCTAssertFalse(texts.joined().contains("banned words"))
        XCTAssertTrue(texts.joined().contains("kept words"))
    }

    func testOutgoingIndexedDespiteForbiddenRecipient() async throws {
        await access.setContact(ServiceIdentity(service: "telegram", accountID: "acc", externalID: "me"), .forbidden)
        await source.add([aiItem(1, text: "my own words", author: "me", outgoing: true)])
        await access.setScope(chat, enabled: true)
        _ = try await indexer().runOnce()
        let texts = try await indexedTexts()
        XCTAssertTrue(texts.joined().contains("my own words"))
    }

    func testDeletedMessageRemovesChunks() async throws {
        await source.add([aiItem(1, text: "to be deleted")])
        await access.setScope(chat, enabled: true)
        let indexer = indexer()
        _ = try await indexer.runOnce()
        await source.add([
            AIIndexItem(
                sequence: 2, identity: MessageArchiveIdentity(service: "telegram", accountID: "acc", conversationID: "c", messageID: "1"),
                scope: chat, author: nil, isOutgoing: false, date: Date(), title: "", text: "", removed: true)
        ])
        _ = try await indexer.runOnce()
        let texts = try await indexedTexts()
        XCTAssertTrue(texts.isEmpty)
    }

    func testEditReplacesOldText() async throws {
        await source.add([aiItem(1, text: "neighbour"), aiItem(2, text: "first draft")])
        await access.setScope(chat, enabled: true)
        let indexer = indexer()
        _ = try await indexer.runOnce()
        await source.edit(messageID: "2", sequence: 3, text: "final wording")
        _ = try await indexer.runOnce()
        let texts = try await indexedTexts().joined(separator: "\n")
        XCTAssertFalse(texts.contains("first draft"))
        XCTAssertTrue(texts.contains("final wording"))
        XCTAssertTrue(texts.contains("neighbour"))
    }

    func testBackfillSkipsDeletedHistory() async throws {
        await source.add([aiItem(1, text: "gone message")])
        await source.add([
            AIIndexItem(
                sequence: 2, identity: MessageArchiveIdentity(service: "telegram", accountID: "acc", conversationID: "c", messageID: "1"),
                scope: chat, author: nil, isOutgoing: false, date: Date(), title: "", text: "", removed: true)
        ])
        let indexer = indexer()
        _ = try await indexer.runOnce()
        await access.setScope(chat, enabled: true)
        _ = try await indexer.runOnce()
        let texts = try await indexedTexts()
        XCTAssertTrue(texts.isEmpty)
    }

    func testDisableDuringEmbeddingDiscardsBatch() async throws {
        await source.add([aiItem(1, text: "in flight")])
        await access.setScope(chat, enabled: true)
        service.embedHold = true
        let indexer = indexer()
        let running = Task { try await indexer.runOnce() }
        let deadline = ContinuousClock.now + .seconds(10)
        while service.embedStarted == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await access.setScope(chat, enabled: false)
        service.embedHold = false
        _ = try await running.value
        let stored = try await indexedTexts()
        XCTAssertTrue(stored.isEmpty)
    }

    func testModelChangeBuildsNewGeneration() async throws {
        await source.add([aiItem(1, text: "searchable")])
        await access.setScope(chat, enabled: true)
        let indexer = indexer()
        _ = try await indexer.runOnce()
        let first = try await vectors.activeGeneration()
        XCTAssertEqual(first?.model, "e1")
        try await worker.assign(.init(role: .embeddings, connectionID: connection.id, model: "e2"), role: .embeddings)
        _ = try await indexer.runOnce()
        let second = try await vectors.activeGeneration()
        XCTAssertEqual(second?.model, "e2")
        XCTAssertNotEqual(second?.id, first?.id)
        let texts = try await indexedTexts()
        XCTAssertEqual(texts.count, 1)
    }

    func testUnauthorizedPausesIndexing() async throws {
        await source.add([aiItem(1, text: "x")])
        await access.setScope(chat, enabled: true)
        service.embedFailure = .unauthorized
        let indexer = indexer()
        let status = try await indexer.runOnce()
        XCTAssertTrue(status.paused)
        XCTAssertEqual(status.failure, .unauthorized)
        let calls = service.embedded.count
        _ = try await indexer.runOnce()
        XCTAssertEqual(service.embedded.count, calls)
        await indexer.pause(false)
        service.embedFailure = nil
        _ = try await indexer.runOnce()
        let texts = try await indexedTexts()
        XCTAssertEqual(texts.count, 1)
    }

    func testCursorOverlapCatchesLateCommit() async throws {
        await access.setScope(chat, enabled: true)
        await source.add([aiItem(10, chat: "c", text: "first")])
        let indexer = indexer()
        _ = try await indexer.runOnce()
        await source.add([aiItem(9, chat: "c", text: "late commit")])
        _ = try await indexer.runOnce()
        let texts = try await indexedTexts()
        XCTAssertTrue(texts.joined().contains("late commit"))
    }

    func testRestartResumesFromCursor() async throws {
        await source.add([aiItem(1, text: "once")])
        await access.setScope(chat, enabled: true)
        _ = try await indexer().runOnce()
        let calls = service.embedded.count
        _ = try await indexer().runOnce()
        XCTAssertEqual(service.embedded.count, calls)
    }

    func testNoEmbeddingRoleDoesNothing() async throws {
        try await worker.assign(nil, role: .embeddings)
        await source.add([aiItem(1, text: "x")])
        await access.setScope(chat, enabled: true)
        let status = try await indexer().runOnce()
        XCTAssertEqual(status.failure, .roleUnassigned(.embeddings))
        XCTAssertTrue(service.embedded.isEmpty)
    }
}

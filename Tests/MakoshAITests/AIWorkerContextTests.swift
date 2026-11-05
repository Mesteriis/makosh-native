import Foundation
import MakoshCore
import XCTest
@testable import MakoshAI

/// Material per card id, or a failure; records which cards were read.
actor AIFakeContextProvider: AIContextProvider {
    private var materials: [String: AIContextMaterial] = [:]
    private var failures: [String: AIFailure] = [:]
    private(set) var reads: [String] = []
    func set(_ card: AIContextCard, text: String, truncated: Bool = false) {
        materials[card.id] = AIContextMaterial(
            card: card, lines: [.init(author: "Мария", isOutgoing: false, date: Date(timeIntervalSince1970: 0), text: text)],
            hiddenForbidden: 0, hiddenProtected: 0, available: 1, requested: 200, truncated: truncated)
    }
    func fail(_ card: AIContextCard, _ failure: AIFailure) { failures[card.id] = failure }
    func material(for card: AIContextCard) async throws -> AIContextMaterial {
        reads.append(card.id)
        if let failure = failures[card.id] { throw failure }
        guard let material = materials[card.id] else { throw AIFailure.contextUnavailable("нет") }
        return material
    }
}

final class AIWorkerContextTests: XCTestCase {
    private var database: AITestDatabase!
    private var service: AIFakeService!
    private var worker: AIWorker!
    private var provider: AIFakeContextProvider!
    private let connection = AIConnection(name: "Synthetic", baseURL: URL(string: "http://127.0.0.1:9/v1")!)
    private let chatA = AIContextCard.chat(service: "telegram", accountID: "1", chatID: "A", title: "Мария", range: .standard)
    private let chatB = AIContextCard.chat(service: "telegram", accountID: "1", chatID: "B", title: "Работа", range: .standard)

    override func setUp() async throws {
        database = try AITestDatabase()
        service = AIFakeService()
        worker = AIWorker(repository: AIRepository(keyProvider: aiTestKey), client: service, vault: AIFakeVault())
        try await worker.open(configuration: database.configuration)
        try await worker.save(connection, token: nil)
        try await worker.assign(.init(role: .chat, connectionID: connection.id, model: "m"), role: .chat)
        provider = AIFakeContextProvider()
        await worker.attachContext(provider)
    }
    override func tearDown() async throws {
        await worker?.close()
        try database?.cleanup()
    }

    private func path(_ conversation: UUID) async throws -> [AIMessage] { AIMessage.path(try await worker.messages(conversation)) }

    func testSendIncludesCardMaterialAndRecordsComposition() async throws {
        await provider.set(chatA, text: "встреча в пять")
        let conversation = try await worker.createConversation(anchor: chatA)
        XCTAssertEqual(conversation.cards, [chatA])
        let (_, error) = await aiDrain(await worker.send("Что обещала?", conversationID: conversation.id, editing: nil))
        XCTAssertNil(error)
        let turns = try XCTUnwrap(service.turns.last)
        XCTAssertEqual(turns.first?.author, .system)
        XCTAssertTrue(turns.first?.text.contains("встреча в пять") == true)
        let messages = try await path(conversation.id)
        XCTAssertEqual(messages.first?.current?.context, [chatA])
        XCTAssertEqual(messages.last?.current?.context, [chatA])
    }

    func testTooLargeContextSavesNothingAndSendsNothing() async throws {
        await provider.set(chatA, text: String(repeating: "x", count: AIContextBuilder.defaultLimit + 1))
        let conversation = try await worker.createConversation(anchor: chatA)
        let (_, error) = await aiDrain(await worker.send("Оцени", conversationID: conversation.id, editing: nil))
        guard case .contextTooLarge? = error as? AIFailure else { return XCTFail("\(String(describing: error))") }
        let stored = try await worker.messages(conversation.id)
        XCTAssertTrue(stored.isEmpty)
        XCTAssertTrue(service.turns.isEmpty)
    }

    func testRegenerateUsesQuestionCompositionNotCurrentCards() async throws {
        await provider.set(chatA, text: "a")
        await provider.set(chatB, text: "b")
        let conversation = try await worker.createConversation(anchor: chatA)
        await aiDrain(await worker.send("Вопрос", conversationID: conversation.id, editing: nil))
        try await worker.setCards([chatB], conversationID: conversation.id)
        let messages = try await path(conversation.id)
        let answer = try XCTUnwrap(messages.last)
        let before = await provider.reads.count
        await aiDrain(await worker.regenerate(answer.id, conversationID: conversation.id))
        let reads = await provider.reads.dropFirst(before)
        XCTAssertEqual(Array(reads), [chatA.id])
    }

    func testUnavailableCardBlocksSend() async throws {
        await provider.fail(chatA, .contextUnavailable("Секретный чат нельзя прикрепить."))
        let conversation = try await worker.createConversation(anchor: chatA)
        let (_, error) = await aiDrain(await worker.send("Вопрос", conversationID: conversation.id, editing: nil))
        XCTAssertEqual(error as? AIFailure, .contextUnavailable("Секретный чат нельзя прикрепить."))
        let stored = try await worker.messages(conversation.id)
        XCTAssertTrue(stored.isEmpty)
        XCTAssertTrue(service.turns.isEmpty)
    }

    func testConversationsFilterByAnchor() async throws {
        let anchored = try await worker.createConversation(anchor: chatA)
        let plain = try await worker.createConversation()
        let other = try await worker.createConversation(anchor: chatB)
        let ofA = try await worker.conversations(anchoredTo: chatA).map(\.id)
        XCTAssertEqual(ofA, [anchored.id])
        let all = Set(try await worker.conversations(anchoredTo: nil).map(\.id))
        XCTAssertEqual(all, [anchored.id, plain.id, other.id])
    }

    func testPlainConversationSendsNoContextTurn() async throws {
        let conversation = try await worker.createConversation()
        await aiDrain(await worker.send("Привет", conversationID: conversation.id, editing: nil))
        XCTAssertNotEqual(service.turns.last?.first?.author, .system)
        let reads = await provider.reads
        XCTAssertTrue(reads.isEmpty)
    }

    func testTruncatedPeriodBlocksSend() async throws {
        await provider.set(chatA, text: "a", truncated: true)
        let conversation = try await worker.createConversation(anchor: chatA)
        let (_, error) = await aiDrain(await worker.send("Оцени", conversationID: conversation.id, editing: nil))
        guard case .contextUnavailable? = error as? AIFailure else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(service.turns.isEmpty)
    }

    func testAnchoredConversationDoesNotSearchOtherData() async throws {
        let anchored = try await worker.createConversation(anchor: chatA)
        XCTAssertFalse(anchored.searchMyData)
        let plain = try await worker.createConversation()
        XCTAssertTrue(plain.searchMyData)
    }

    func testConcurrentCardChangesKeepBoth() async throws {
        let conversation = try await worker.createConversation(anchor: chatA)
        let worker = self.worker!, chatB = self.chatB
        let letter = AIContextCard.letter(id: "L", title: "Счёт")
        async let first: Void = worker.addCard(chatB, conversationID: conversation.id)
        async let second: Void = worker.addCard(letter, conversationID: conversation.id)
        _ = try await (first, second)
        let cards = try await worker.conversations(anchoredTo: chatA).first?.cards.map(\.id)
        XCTAssertEqual(Set(cards ?? []), [chatA.id, chatB.id, letter.id])
    }

    func testCardChangeDuringSendIsNotUndone() async throws {
        await provider.set(chatA, text: "a")
        await provider.set(chatB, text: "b")
        let conversation = try await worker.createConversation(anchor: chatA)
        try await worker.addCard(chatB, conversationID: conversation.id)
        let worker = self.worker!, chatB = self.chatB
        async let sent = aiDrain(await worker.send("Вопрос", conversationID: conversation.id, editing: nil))
        async let removed: Void = worker.removeCard(chatB.id, conversationID: conversation.id)
        _ = await sent
        try await removed
        let cards = try await worker.conversations(anchoredTo: chatA).first?.cards.map(\.id)
        XCTAssertEqual(cards, [chatA.id])
    }
}

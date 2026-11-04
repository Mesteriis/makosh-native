import MakoshCore
import XCTest
@testable import MakoshAI

final class AIRetrievalTests: XCTestCase {
    private var database: AITestDatabase!
    private var service: AIFakeService!
    private var worker: AIWorker!
    private var vectors: AIVectorStore!
    private var access: AIFakeAccess!
    private let connection = AIConnection(name: "Synthetic", baseURL: URL(string: "http://127.0.0.1:9/v1")!)
    private let chat = AIAccessScope.conversation(service: "telegram", accountID: "acc", conversationID: "c")
    private let message = MessageArchiveIdentity(service: "telegram", accountID: "acc", conversationID: "c", messageID: "1")

    override func setUp() async throws {
        database = try AITestDatabase()
        service = AIFakeService()
        worker = AIWorker(repository: AIRepository(keyProvider: aiTestKey), client: service, vault: AIFakeVault())
        try await worker.open(configuration: database.configuration)
        try await worker.save(connection, token: nil)
        try await worker.assign(.init(role: .chat, connectionID: connection.id, model: "m"), role: .chat)
        try await worker.assign(.init(role: .embeddings, connectionID: connection.id, model: "e1"), role: .embeddings)
        vectors = AIVectorStore(keyProvider: aiTestKey)
        try await vectors.open(configuration: database.configuration)
        access = AIFakeAccess()
        await worker.attachRetrieval(vectors: vectors, access: access)
    }
    override func tearDown() async throws {
        await vectors?.close()
        await worker?.close()
        try database?.cleanup()
    }

    /// Stores one chunk whose fake embedding equals the question's ("П…" both map to the same axis).
    private func indexChunk(text: String = "Пётр прислал отчёт в пятницу") async throws {
        let generation = try await vectors.generation(connectionID: connection.id, model: "e1", dimensions: service.dimensions)
        let vector = try await service.embeddings(connection: connection, token: nil, model: "e1", inputs: [text])[0]
        try await vectors.insert(
            [(AIChunk(id: "chunk", scope: chat, messages: [message], authors: [], text: text, date: Date(timeIntervalSince1970: 50), title: "Работа"), vector)],
            generation: generation.id)
        try await vectors.markReady(generation.id)
    }
    private func send(_ text: String = "Привет, что прислал Пётр?") async throws -> AIConversation {
        let conversation = try await worker.createConversation()
        await aiDrain(await worker.send(text, conversationID: conversation.id, editing: nil))
        return conversation
    }

    func testAnswerCarriesSources() async throws {
        try await indexChunk()
        await access.setScope(chat, enabled: true)
        let conversation = try await send()
        let turns = try XCTUnwrap(service.turns.last)
        XCTAssertEqual(turns.first?.author, .system)
        XCTAssertTrue(turns.first?.text.contains("[1]") == true && turns.first?.text.contains("Пётр прислал отчёт") == true)
        XCTAssertEqual(turns.last, .init(author: .user, text: "Привет, что прислал Пётр?"))
        let messages = try await worker.messages(conversation.id)
        let answer = try XCTUnwrap(AIMessage.path(messages).last?.current)
        XCTAssertEqual(answer.sources, [AISourceReference(identity: message, title: "Работа", date: Date(timeIntervalSince1970: 50))])
    }

    func testRetrievalRechecksAdmission() async throws {
        try await indexChunk()
        let conversation = try await send()
        XCTAssertFalse(service.turns.last?.contains { $0.author == .system } == true)
        let answer = AIMessage.path(try await worker.messages(conversation.id)).last?.current
        XCTAssertEqual(answer?.sources, [])
    }

    func testSearchDisabledSendsNoEmbeddings() async throws {
        try await indexChunk()
        await access.setScope(chat, enabled: true)
        let conversation = try await worker.createConversation()
        try await worker.setSearchMyData(false, conversationID: conversation.id)
        let before = service.embedded.count
        await aiDrain(await worker.send("Привет", conversationID: conversation.id, editing: nil))
        XCTAssertEqual(service.embedded.count, before)
        XCTAssertFalse(service.turns.last?.contains { $0.author == .system } == true)
        let stored = try await worker.snapshot().conversations.first { $0.id == conversation.id }
        XCTAssertEqual(stored?.searchMyData, false)
    }

    func testNoGenerationFallsBackToPlainChat() async throws {
        await access.setScope(chat, enabled: true)
        let conversation = try await send()
        XCTAssertEqual(service.turns.last, [.init(author: .user, text: "Привет, что прислал Пётр?")])
        let answer = AIMessage.path(try await worker.messages(conversation.id)).last?.current
        XCTAssertEqual(answer?.state, .complete)
    }

    func testOldVersionsDecodeWithoutSources() throws {
        let version = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"x","state":"complete","createdAt":0}"#
        XCTAssertEqual(try JSONDecoder().decode(AIMessageVersion.self, from: Data(version.utf8)).sources, [])
        let conversation = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","createdAt":0,"updatedAt":0}"#
        XCTAssertTrue(try JSONDecoder().decode(AIConversation.self, from: Data(conversation.utf8)).searchMyData)
    }
}

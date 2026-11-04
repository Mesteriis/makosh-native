import MakoshCore
import XCTest
@testable import MakoshAI

final class AIVectorStoreTests: XCTestCase {
    private var database: AITestDatabase!
    private var store: AIVectorStore!
    private let connection = UUID()
    private let chat = AIAccessScope.conversation(service: "telegram", accountID: "acc", conversationID: "c")
    private let author = ServiceIdentity(service: "telegram", accountID: "acc", externalID: "42")

    override func setUp() async throws {
        database = try AITestDatabase()
        store = AIVectorStore(keyProvider: aiTestKey)
        try await store.open(configuration: database.configuration)
    }
    override func tearDown() async throws {
        await store?.close()
        try database?.cleanup()
    }

    private func chunk(_ id: String, scope: AIAccessScope? = nil, authors: [ServiceIdentity] = [], message: String = "1", text: String = "secret text")
        -> AIChunk
    {
        AIChunk(
            id: id, scope: scope ?? chat,
            messages: [MessageArchiveIdentity(service: "telegram", accountID: "acc", conversationID: "c", messageID: message)],
            authors: authors, text: text, date: Date(timeIntervalSince1970: 100), title: "Chat")
    }

    func testUnavailableWithoutExtension() async throws {
        let missing = AIVectorStore(keyProvider: aiTestKey, extensionName: "makosh_missing_extension")
        try await missing.open(configuration: database.configuration)
        let available = try await missing.available()
        XCTAssertFalse(available)
        await missing.close()
        let real = try await store.available()
        XCTAssertTrue(real)
    }

    func testInsertSearchNearestFirst() async throws {
        let generation = try await store.generation(connectionID: connection, model: "e", dimensions: 3)
        try await store.insert([(chunk("a", text: "alpha"), [1, 0, 0]), (chunk("b", message: "2", text: "beta"), [0, 1, 0])], generation: generation.id)
        let matches = try await store.search([0.9, 0.1, 0], generation: generation.id, limit: 8, maxDistance: 2)
        XCTAssertEqual(matches.map(\.chunk.text), ["alpha", "beta"])
        XCTAssertLessThan(matches[0].distance, matches[1].distance)
        let close = try await store.search([1, 0, 0], generation: generation.id, limit: 8, maxDistance: 0.5)
        XCTAssertEqual(close.map(\.chunk.id), ["a"])
        let existing = try await store.contains(["a", "zzz"], generation: generation.id)
        XCTAssertEqual(existing, ["a"])
    }

    func testGenerationsDoNotMix() async throws {
        let old = try await store.generation(connectionID: connection, model: "old", dimensions: 2)
        let new = try await store.generation(connectionID: connection, model: "new", dimensions: 3)
        XCTAssertNotEqual(old.id, new.id)
        let again = try await store.generation(connectionID: connection, model: "old", dimensions: 2)
        XCTAssertEqual(again.id, old.id)
        try await store.insert([(chunk("a"), [1, 0])], generation: old.id)
        try await store.markReady(old.id)
        let active = try await store.activeGeneration()
        XCTAssertEqual(active?.id, old.id)
        try await store.insert([(chunk("b"), [0, 0, 1])], generation: new.id)
        let fromNew = try await store.search([0, 0, 1], generation: new.id, limit: 8, maxDistance: 2)
        XCTAssertEqual(fromNew.map(\.chunk.id), ["b"])
        try await store.markReady(new.id)
        let activeNew = try await store.activeGeneration()
        XCTAssertEqual(activeNew?.id, new.id)
        let oldLeft = try await store.contains(["a"], generation: old.id)
        XCTAssertTrue(oldLeft.isEmpty)
    }

    func testDeleteByScopeAuthorMessage() async throws {
        let g = try await store.generation(connectionID: connection, model: "e", dimensions: 2).id
        let other = AIAccessScope.mailAccount(accountID: "m")
        try await store.insert(
            [
                (chunk("scope", scope: chat), [1, 0]), (chunk("author", scope: other, authors: [author], message: "7"), [1, 0]),
                (chunk("message", scope: other, message: "9"), [1, 0]),
            ], generation: g)
        try await store.delete(author: author)
        var left = try await store.contains(["scope", "author", "message"], generation: g)
        XCTAssertEqual(left, ["scope", "message"])
        try await store.delete(scope: chat)
        left = try await store.contains(["scope", "message"], generation: g)
        XCTAssertEqual(left, ["message"])
        try await store.delete(message: MessageArchiveIdentity(service: "telegram", accountID: "acc", conversationID: "c", messageID: "9"))
        left = try await store.contains(["message"], generation: g)
        XCTAssertTrue(left.isEmpty)
    }

    func testChunkTextEncrypted() async throws {
        let g = try await store.generation(connectionID: connection, model: "e", dimensions: 2).id
        try await store.insert([(chunk("a", text: "very private words"), [1, 0])], generation: g)
        let rows = try database.execute("SELECT chunk_token,scope_token,ciphertext FROM \"\(database.configuration.schema)\".ai_chunks")
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows.flatMap { $0 }.joined().contains("very private"))
        XCTAssertFalse(rows.flatMap { $0 }.joined().contains("telegram"))
    }

    func testDimensionAbove2000Rejected() async throws {
        do {
            _ = try await store.generation(connectionID: connection, model: "huge", dimensions: 3072)
            XCTFail("accepted 3072 dimensions")
        } catch { XCTAssertEqual(error as? AIFailure, .dimensionsTooLarge) }
    }
}

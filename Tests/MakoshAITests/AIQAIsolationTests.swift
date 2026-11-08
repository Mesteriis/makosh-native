import MakoshCore
import XCTest
@testable import MakoshAI

final class AIQAIsolationTests: XCTestCase {
    private let arguments = ["/Applications/Makosh", "--ai-synthetic-preview", "--database-config", "/tmp/qa.json"]
    private func configuration(schema: String = "qa_ai_preview", host: String = "127.0.0.1") -> PersonWorkspaceConfiguration {
        .init(
            connectionString: "host=\(host) hostaddr=127.0.0.1 port=5432 dbname=makosh user=makosh", schema: schema, archiveSchema: schema)
    }

    func testQAIsolationAcceptsQAPrefixOnLoopback() {
        XCTAssertNoThrow(try AIQAIsolation.validate(configuration: configuration(), arguments: arguments))
    }

    func testQAIsolationRequiresQAPrefix() {
        XCTAssertThrowsError(try AIQAIsolation.validate(configuration: configuration(schema: "makosh"), arguments: arguments))
        XCTAssertThrowsError(try AIQAIsolation.validate(configuration: configuration(schema: "qa_ai_"), arguments: arguments))
    }

    func testQAIsolationRejectsRemoteHost() {
        XCTAssertThrowsError(try AIQAIsolation.validate(configuration: configuration(host: "db.example.com"), arguments: arguments))
    }

    func testQAIsolationRejectsUnknownFlag() {
        XCTAssertThrowsError(
            try AIQAIsolation.validate(configuration: configuration(), arguments: arguments + ["--telegram-synthetic-preview"]))
        XCTAssertThrowsError(
            try AIQAIsolation.validate(configuration: configuration(), arguments: ["/Applications/Makosh", "--ai-synthetic-preview"]))
    }

    func testSyntheticServiceStreamsWithoutNetwork() async throws {
        let service = AISyntheticService()
        let connection = AIConnection(name: "QA", baseURL: URL(string: "http://127.0.0.1:9/v1")!)
        var text = ""
        for try await event in service.chat(
            connection: connection, token: nil, model: "synthetic-chat", turns: [.init(author: .user, text: "Привет")])
        {
            if case .delta(let delta) = event { text += delta }
        }
        XCTAssertFalse(text.isEmpty)
        let models = try await service.models(connection: connection, token: nil)
        XCTAssertEqual(models, ["synthetic-chat", "synthetic-embed", "synthetic-image", "synthetic-speech", "synthetic-transcribe"])
    }

    func testSyntheticEmbeddingsDeterministic() async throws {
        let service = AISyntheticService()
        let connection = AIConnection(name: "QA", baseURL: URL(string: "http://127.0.0.1:9/v1")!)
        let first = try await service.embeddings(
            connection: connection, token: nil, model: "synthetic-embed", inputs: ["отчёт", "отчёт", "погода"])
        XCTAssertEqual(first[0], first[1])
        XCTAssertNotEqual(first[0], first[2])
        XCTAssertEqual(first[0].count, 16)
    }

    func testSyntheticPreviewSeedsEnabledConversation() throws {
        let database = try AITestDatabase()
        defer { try? database.cleanup() }
        let store = try MessageArchiveStore(
            connectionString: database.configuration.connectionString, schema: database.configuration.schema
        ) { _, _ in
            Data(repeating: 0x5a, count: 32)
        }
        let scope = try AISyntheticSeed.seed(store)
        XCTAssertEqual(try store.enabledAIScopes(), [scope])
        XCTAssertGreaterThanOrEqual(try store.records(after: 0, limit: 200).count, 4)
        let seeded = try store.records(after: 0, limit: 200).count
        let again = try AISyntheticSeed.seed(store)
        XCTAssertEqual(again, scope)
        XCTAssertEqual(try store.records(after: 0, limit: 200).count, seeded)
    }
}

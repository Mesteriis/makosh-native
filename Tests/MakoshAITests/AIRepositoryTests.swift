import CPostgres
import MakoshCore
import XCTest
@testable import MakoshAI

struct AITestDatabase: Sendable {
    let configuration: ContactWorkspaceConfiguration
    init() throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !dsn.isEmpty else { throw AIFailure.storage }
        let schema = "qa_ai_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        configuration = .init(connectionString: dsn, schema: schema, archiveSchema: schema)
    }
    @discardableResult
    func execute(_ sql: String) throws -> [[String]] {
        guard let connection = PQconnectdb(configuration.connectionString) else { throw AIFailure.storage }
        defer { PQfinish(connection) }
        guard PQstatus(connection) == CONNECTION_OK else { throw AIFailure.storage }
        PQsetNoticeProcessor(connection, { _, _ in }, nil)
        guard let result = PQexec(connection, sql) else { throw AIFailure.storage }
        defer { PQclear(result) }
        guard [PGRES_TUPLES_OK, PGRES_COMMAND_OK].contains(PQresultStatus(result)) else { throw AIFailure.storage }
        return (0..<PQntuples(result)).map { row in (0..<PQnfields(result)).map { String(cString: PQgetvalue(result, row, $0)) } }
    }
    func cleanup() throws {
        guard configuration.schema.hasPrefix("qa_ai_"), configuration.schema.count == 38 else { throw AIFailure.storage }
        try execute("DROP SCHEMA IF EXISTS \"\(configuration.schema)\" CASCADE")
    }
}

let aiTestKey: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x61, count: 32) }

final class AIRepositoryTests: XCTestCase {
    private var database: AITestDatabase!
    private var repository: AIRepository!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        database = try AITestDatabase()
        repository = AIRepository(keyProvider: aiTestKey)
        try await repository.open(configuration: database.configuration)
    }
    override func tearDown() async throws {
        await repository?.close()
        try database?.cleanup()
    }

    private func connection(_ name: String = "Cloud secret name") -> AIConnection {
        AIConnection(name: name, baseURL: URL(string: "https://api.example.com/v1")!)
    }
    private func message(_ conversation: UUID, parent: UUID? = nil, image: AIImageReference? = nil) -> AIMessage {
        AIMessage(
            conversationID: conversation, parentID: parent, author: .assistant,
            versions: [
                .init(text: "first", state: .complete, model: "m", createdAt: date, image: image),
                .init(text: "second", state: .interrupted, model: "m", createdAt: date),
            ], selectedVersion: 1)
    }

    func testConnectionsRoundTripEncrypted() async throws {
        let value = connection()
        try await repository.save(value)
        let loaded = try await repository.connections()
        XCTAssertEqual(loaded, [value])
        let rows = try database.execute("SELECT ciphertext FROM \"\(database.configuration.schema)\".ai_records")
        XCTAssertFalse(rows.flatMap { $0 }.joined().contains("Cloud secret name"))
        XCTAssertFalse(rows.isEmpty)
    }

    func testRemovingConnectionClearsItsRoles() async throws {
        let kept = connection("Kept"), removed = connection("Removed")
        try await repository.save(kept)
        try await repository.save(removed)
        try await repository.assign(.init(role: .chat, connectionID: removed.id, model: "a"), role: .chat)
        try await repository.assign(.init(role: .speech, connectionID: kept.id, model: "b"), role: .speech)
        try await repository.removeConnection(removed.id)
        let connections = try await repository.connections()
        let roles = try await repository.roles()
        XCTAssertEqual(connections.map(\.id), [kept.id])
        XCTAssertEqual(roles, [.init(role: .speech, connectionID: kept.id, model: "b")])
    }

    func testAssignNilClearsRole() async throws {
        let value = connection()
        try await repository.save(value)
        try await repository.assign(.init(role: .chat, connectionID: value.id, model: "a"), role: .chat)
        try await repository.assign(nil, role: .chat)
        let roles = try await repository.roles()
        XCTAssertTrue(roles.isEmpty)
    }

    func testConversationOrderByUpdatedAt() async throws {
        let old = AIConversation(title: "old", createdAt: date, updatedAt: date)
        let new = AIConversation(title: "new", createdAt: date, updatedAt: date.addingTimeInterval(60))
        try await repository.save(old)
        try await repository.save(new)
        let loaded = try await repository.conversations()
        XCTAssertEqual(loaded.map(\.title), ["new", "old"])
    }

    func testMessagesVersionsRoundTrip() async throws {
        let conversation = AIConversation(title: "c", createdAt: date, updatedAt: date)
        try await repository.save(conversation)
        let first = message(conversation.id)
        let second = message(conversation.id, parent: first.id)
        try await repository.save(first)
        try await repository.save(second)
        var updated = second
        updated.versions[1].text = "second, finished"
        try await repository.save(updated)
        let loaded = try await repository.messages(conversationID: conversation.id)
        XCTAssertEqual(Set(loaded.map(\.id)), [first.id, second.id])
        XCTAssertEqual(loaded.first { $0.id == second.id }, updated)
    }

    func testDeleteConversationRemovesMessagesAndReturnsImages() async throws {
        let conversation = AIConversation(title: "c", createdAt: date, updatedAt: date)
        let image = AIImageReference(
            objectID: UUID(), byteCount: 3, sha256: "abc", plaintextByteCount: 1, key: Data(repeating: 1, count: 32), inS3: true)
        try await repository.save(conversation)
        try await repository.save(message(conversation.id, image: image))
        let images = try await repository.deleteConversation(conversation.id)
        XCTAssertEqual(images, [image])
        let conversations = try await repository.conversations()
        let messages = try await repository.messages(conversationID: conversation.id)
        XCTAssertTrue(conversations.isEmpty)
        XCTAssertTrue(messages.isEmpty)
    }

    func testDeleteDoesNotTouchOtherConversations() async throws {
        let deleted = AIConversation(title: "d", createdAt: date, updatedAt: date)
        let kept = AIConversation(title: "k", createdAt: date, updatedAt: date)
        try await repository.save(deleted)
        try await repository.save(kept)
        try await repository.save(message(deleted.id))
        let keptMessage = message(kept.id)
        try await repository.save(keptMessage)
        _ = try await repository.deleteConversation(deleted.id)
        let conversations = try await repository.conversations()
        let messages = try await repository.messages(conversationID: kept.id)
        XCTAssertEqual(conversations, [kept])
        XCTAssertEqual(messages, [keptMessage])
    }

    func testReopenWithWrongKeyFails() async throws {
        try await repository.save(connection())
        await repository.close()
        let other = AIRepository(keyProvider: { _, _ in Data(repeating: 0x62, count: 32) })
        do {
            try await other.open(configuration: database.configuration)
            XCTFail("opened with a different key")
        } catch { XCTAssertEqual(error as? AIFailure, .keyUnavailable) }
    }

    func testImagesSavedToS3DefaultsOn() async throws {
        let initial = try await repository.imagesSavedToS3()
        XCTAssertTrue(initial)
        try await repository.setImagesSavedToS3(false)
        let changed = try await repository.imagesSavedToS3()
        XCTAssertFalse(changed)
    }
}

import XCTest
import CPostgres
import MakoshCore
@testable import MakoshTelemost

struct TelemostTestDatabase: Sendable {
    let configuration: ContactWorkspaceConfiguration
    init() throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !dsn.isEmpty else { throw TelemostFailure.storage }
        let schema = "qa_telemost_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        configuration = .init(connectionString: dsn, schema: schema, archiveSchema: schema)
    }
    @discardableResult
    func execute(_ sql: String) throws -> [[String]] {
        guard let connection = PQconnectdb(configuration.connectionString) else { throw TelemostFailure.storage }
        defer { PQfinish(connection) }
        guard PQstatus(connection) == CONNECTION_OK else { throw TelemostFailure.storage }
        PQsetNoticeProcessor(connection, { _, _ in }, nil)
        guard let result = PQexec(connection, sql) else { throw TelemostFailure.storage }
        defer { PQclear(result) }
        guard [PGRES_TUPLES_OK, PGRES_COMMAND_OK].contains(PQresultStatus(result)) else { throw TelemostFailure.storage }
        return (0..<PQntuples(result)).map { row in (0..<PQnfields(result)).map { String(cString: PQgetvalue(result, row, $0)) } }
    }
    func cleanup() throws {
        guard configuration.schema.hasPrefix("qa_telemost_"), configuration.schema.count == 44 else { throw TelemostFailure.storage }
        try execute("DROP SCHEMA IF EXISTS \"\(configuration.schema)\" CASCADE")
    }
}
let telemostTestKey: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x74, count: 32) }
let telemostTestAccount = TelemostAccount(id: telemostTestAccountID, name: "Synthetic account", clientID: String(repeating: "a", count: 32),
    callbackURL: URL(string: "org.makosh.desktop.telemost://oauth/callback")!, capabilities: [.read, .create, .update])
let telemostTestScope = TelemostScope(accountID: telemostTestAccountID, conferenceID: "123")

func telemostTestConference(_ waitingRoom: String = "ADMINS") throws -> TelemostConference {
    .init(scope: telemostTestScope, joinURL: try .init("https://telemost.yandex.ru/j/123"), waitingRoomRaw: waitingRoom,
          observedAt: Date(timeIntervalSince1970: 100), retainedJSON: Data(#"{"id":"123","waiting_room_level":"\#(waitingRoom)"}"#.utf8))
}

@MainActor
final class TelemostRepositoryTests: XCTestCase {
    func database() throws -> TelemostTestDatabase {
        let db = try TelemostTestDatabase(); addTeardownBlock { try db.cleanup() }; return db
    }
    func repository(_ db: TelemostTestDatabase) async throws -> TelemostRepository {
        let repo = TelemostRepository(keyProvider: telemostTestKey); try await repo.open(configuration: db.configuration)
        addTeardownBlock { await repo.close() }; try await repo.saveAccount(telemostTestAccount); return repo
    }
    func testPermanentVersionsAndLocalAreaIsolation() async throws {
        let db = try database(), repo = try await repository(db)
        try await repo.retain(telemostTestConference())
        try await repo.retain(telemostTestConference())
        try await repo.retain(telemostTestConference("PUBLIC"))
        let history = try await repo.history(scope: telemostTestScope, before: nil, limit: 50)
        XCTAssertEqual(history.map(\.waitingRoomRaw), ["PUBLIC", "ADMINS"])
        let local = TelemostLocalMeeting(accountID: nil, validatedURL: try .init("https://telemost.yandex.ru/j/123"), localTitle: "Guest local")
        try await repo.saveLocal(local)
        let guest = try await repo.page(accountID: nil, query: "", before: nil, limit: 50)
        let account = try await repo.page(accountID: telemostTestAccountID, query: "", before: nil, limit: 50)
        XCTAssertEqual(guest.values.map(\.localTitle), ["Guest local"])
        XCTAssertEqual(account.values.count, 1)
        XCTAssertNotEqual(account.values[0].id, local.id)
    }
    func testStablePagingAndJSONLUpperBound() async throws {
        let db = try database(), repo = try await repository(db)
        for i in 0..<65 {
            try await repo.saveLocal(.init(accountID: nil, validatedURL: try .init("https://telemost.yandex.ru/j/\(i)"), localTitle: "Meeting \(i)"))
        }
        let first = try await repo.page(accountID: nil, query: "Meeting", before: nil, limit: 50)
        XCTAssertEqual(first.values.count, 50); XCTAssertNotNil(first.next)
        var modified = first.values[0]; modified.localTitle = "Changed after cursor"
        try await repo.saveLocal(modified)
        try await repo.saveLocal(.init(accountID: nil, validatedURL: try .init("https://telemost.yandex.ru/j/999"), localTitle: "Meeting new"))
        let second = try await repo.page(accountID: nil, query: "Meeting", before: first.next, limit: 50)
        XCTAssertEqual(second.values.count, 15); XCTAssertNil(second.next)
        XCTAssertEqual(Set((first.values + second.values).map(\.id)).count, 65)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let count = try await repo.export(accountID: nil, to: file)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(count, 67); XCTAssertEqual(lines.count, count)
        XCTAssertFalse(lines.contains { $0.contains("access_token") })
    }
    func testHideAndRemoteMissingRetainHistory() async throws {
        let db = try database(), repo = try await repository(db)
        try await repo.retain(telemostTestConference())
        let page = try await repo.page(accountID: telemostTestAccountID, query: "", before: nil, limit: 50)
        var value = try XCTUnwrap(page.values.first); value.hidden = true
        try await repo.saveLocal(value); try await repo.markUnavailable(scope: telemostTestScope)
        let hidden = try await repo.page(accountID: telemostTestAccountID, query: "", before: nil, limit: 50)
        let history = try await repo.history(scope: telemostTestScope, before: nil, limit: 50)
        XCTAssertEqual(hidden.values.count, 1); XCTAssertEqual(hidden.values.first?.hidden, true); XCTAssertEqual(hidden.values.first?.unavailable, true); XCTAssertEqual(history.count, 1)
    }
    func testMissingKeyAndUnsupportedSchemaFailClosed() async throws {
        let db = try database(), repo = try await repository(db)
        try await repo.retain(telemostTestConference()); await repo.close()
        let missing = TelemostRepository(keyProvider: { _, _ in throw TelemostFailure.keyUnavailable })
        do { try await missing.open(configuration: db.configuration); XCTFail("missing key accepted") } catch {}
        let count = try db.execute("SELECT count(*) FROM \"\(db.configuration.schema)\".telemost_versions")
        XCTAssertEqual(count[0][0], "2") // conference + catalogue projection
        try db.execute("UPDATE \"\(db.configuration.schema)\".telemost_metadata SET version=99")
        let unsupported = TelemostRepository(keyProvider: telemostTestKey)
        do { try await unsupported.open(configuration: db.configuration); XCTFail("future schema accepted") } catch {}
    }
    func testCiphertextContainsNoFixtureContent() async throws {
        let db = try database(), repo = try await repository(db)
        try await repo.saveLocal(.init(accountID: nil, validatedURL: try .init("https://telemost.yandex.ru/j/321"), localTitle: "Synthetic meeting"))
        let rows = try db.execute("SELECT ciphertext FROM \"\(db.configuration.schema)\".telemost_records UNION ALL SELECT ciphertext FROM \"\(db.configuration.schema)\".telemost_versions")
        XCTAssertFalse(rows.isEmpty)
        for row in rows { XCTAssertFalse(row[0].contains("Synthetic meeting")); XCTAssertFalse(row[0].contains("telemost.yandex.ru")) }
    }
    func testFailedCommitBlocksAllSetters() throws {
        let fixture = try database()
        let db = try TelemostPostgres(configuration: fixture.configuration); try db.open(keyProvider: telemostTestKey); defer { db.close() }
        XCTAssertThrowsError(try db.transaction {
            try db.query("CREATE TABLE " + db.prefix + "commit_probe(id INT UNIQUE DEFERRABLE INITIALLY DEFERRED)")
            try db.query("INSERT INTO " + db.prefix + "commit_probe VALUES(1),(1)")
        })
        XCTAssertTrue(db.blocked)
        XCTAssertThrowsError(try db.query("CREATE TABLE " + db.prefix + "unsafe_direct_write(id INT)"))
    }
    func testStaleLocalEditCannotOverwriteNewerFields() async throws {
        let db = try database(), repo = try await repository(db)
        let original = TelemostLocalMeeting(accountID: nil, validatedURL: try .init("https://telemost.yandex.ru/j/789"), localTitle: "Initial")
        try await repo.saveLocal(original)
        var newer = original; newer.notes = "New note in another window"
        try await repo.saveLocal(newer)
        var stale = original; stale.localTitle = "Stale edit"
        do { try await repo.saveLocal(stale); XCTFail("stale edit overwrote a later note") } catch {}
        let retained = try await repo.meeting(id: original.id)
        XCTAssertEqual(retained.notes, "New note in another window")
        XCTAssertEqual(retained.localTitle, "Initial")
    }
}

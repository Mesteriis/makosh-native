import XCTest
import MakoshCore
@testable import MakoshTeams

@MainActor
final class TeamsArchiveTests: XCTestCase {
    func testExportRefusesUnprojectedVersionsAndKeepsExactPayload() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        _ = try await repository.commit(page: TeamsPage(values: [teamsTestMessage("export", metadata: ["subject": "exact payload"])], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        let pending = try await repository.pendingProjection(limit: 50)
        let blocked = TeamsArchiveProjection(configuration: db.configuration, repository: repository, keyProvider: { _, _ in throw MessageArchiveError.keyUnavailable })
        do { _ = try await blocked.export(scope: teamsTestScope); XCTFail("Incomplete export accepted") } catch {}
        let projection = TeamsArchiveProjection(configuration: db.configuration, repository: repository, keyProvider: teamsTestKey)
        let lease = try await projection.export(scope: teamsTestScope)
        let lines = try String(contentsOf: lease.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let json = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        let observation = json?["observation"] as? [String: Any]
        XCTAssertEqual(observation?["sourcePayload"] as? String, pending.first?.observation.sourcePayload?.base64EncodedString())
        await lease.release(); await repository.close()
    }
    func testArchiveProjectionCrashReplaysExactObservation() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        for message in [teamsTestMessage("same", metadata: ["importance": "normal"]), teamsTestMessage("same", modified: 21, metadata: ["importance": "high"])] {
            _ = try await repository.commit(page: TeamsPage(values: [message], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        }
        let original = try await repository.pendingProjection(limit: 50)
        XCTAssertEqual(original.count, 2)
        // Crash after Core commit, before acknowledgement: append receives the exact persisted UUID/date/payload again.
        let archive = try MessageArchiveStore(connectionString: db.configuration.connectionString, schema: db.configuration.schema, keyProvider: teamsTestKey)
        XCTAssertEqual(try archive.append(original.map(\.observation)), 2)
        let reopened = TeamsRepository(keyProvider: teamsTestKey)
        try await reopened.open(configuration: db.configuration)
        let projector = TeamsArchiveProjection(configuration: db.configuration, repository: reopened, keyProvider: teamsTestKey)
        try await projector.drain()
        let pending = try await reopened.pendingProjection(limit: 50)
        XCTAssertTrue(pending.isEmpty)
        let records = try archive.records(service: "teams", accountID: teamsTestContext.accountID.uuidString,
            conversationID: teamsTestScope.archiveConversationID)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map { $0.observation.id }), Set(original.map { $0.observation.id }))
        XCTAssertEqual(records.last?.observation.observedAt, original.first?.observation.observedAt)
    }
}

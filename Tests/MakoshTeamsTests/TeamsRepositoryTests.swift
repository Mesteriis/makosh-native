import XCTest
import CPostgres
import MakoshCore
@testable import MakoshTeams

struct TeamsTestDatabase: Sendable {
    let configuration: ContactWorkspaceConfiguration
    init() throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !dsn.isEmpty else {
            throw NSError(domain: "Teams tests require PostgreSQL", code: 1)
        }
        let schema = "qa_teams_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        configuration = ContactWorkspaceConfiguration(connectionString: dsn, schema: schema, archiveSchema: schema)
    }
    @discardableResult
    func execute(_ sql: String) throws -> [[String]] {
        let connection = PQconnectdb(configuration.connectionString)
        guard let connection else { throw NSError(domain: "Teams test database", code: 1) }
        defer { PQfinish(connection) }
        guard PQstatus(connection) == CONNECTION_OK else { throw NSError(domain: "Teams test database", code: 2) }
        PQsetNoticeProcessor(connection, { _, _ in }, nil)
        guard let result = PQexec(connection, sql) else { throw NSError(domain: "Teams test database", code: 3) }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_TUPLES_OK || PQresultStatus(result) == PGRES_COMMAND_OK else { throw NSError(domain: "Teams test database", code: 4) }
        return (0..<PQntuples(result)).map { row in (0..<PQnfields(result)).map { String(cString: PQgetvalue(result, row, $0)) } }
    }
    func cleanup() throws {
        guard configuration.schema.hasPrefix("qa_teams_"), configuration.schema.count == 41 else { throw NSError(domain: "Refused test cleanup", code: 1) }
        try execute("DROP SCHEMA IF EXISTS \"\(configuration.schema)\" CASCADE")
    }
}

let teamsTestKey: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x52, count: 32) }
let teamsTestScope = TeamsScope(accountID: teamsTestContext.accountID, tenantID: teamsTestContext.principal.tenantID, resource: .chat("test-chat"))
let teamsTestCollection = TeamsCollection(context: teamsTestContext, kind: .messages(.chat("test-chat")))

func teamsTestMessage(_ body: String, id: String = "m1", modified: TimeInterval = 20, deleted: Bool = false,
                      metadata: [String: String] = [:]) -> TeamsMessage {
    TeamsMessage(id: id, scope: teamsTestScope, body: body, contentType: "text", author: nil,
        createdAt: Date(timeIntervalSince1970: 10), modifiedAt: Date(timeIntervalSince1970: modified),
        deletedAt: deleted ? Date(timeIntervalSince1970: modified) : nil, attachments: [], replyTo: nil, metadata: metadata)
}

func teamsTestRepository(_ db: TeamsTestDatabase) async throws -> TeamsRepository {
    let repository = TeamsRepository(keyProvider: teamsTestKey)
    try await repository.open(configuration: db.configuration)
    try await repository.saveAccount(TeamsAccount(id: teamsTestContext.accountID, name: "Synthetic", clientID: "44444444-4444-4444-8444-444444444444",
        authority: "organizations", verifiedPrincipal: teamsTestContext.principal, readOnly: false))
    return repository
}

@MainActor
final class TeamsRepositoryTests: XCTestCase {
    func database() throws -> TeamsTestDatabase {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }; return db
    }
    // A late invalid item must roll back every version, projection job and cursor from its page.
    func testFailedCommitBlocksDirectQueries() throws {
        let fixture = try TeamsTestDatabase(); defer { try? fixture.cleanup() }
        let db = try TeamsPostgres(configuration: fixture.configuration); try db.open(keyProvider: teamsTestKey); defer { db.close() }
        XCTAssertThrowsError(try db.transaction {
            try db.query("CREATE TABLE " + db.prefix + "commit_probe(id INT UNIQUE DEFERRABLE INITIALLY DEFERRED)")
            try db.query("INSERT INTO " + db.prefix + "commit_probe VALUES(1),(1)")
        })
        XCTAssertTrue(db.blocked)
        XCTAssertThrowsError(try db.query("CREATE TABLE " + db.prefix + "unsafe_direct_write(id INT)"))
        let rows = try fixture.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='" + fixture.configuration.schema + "' AND table_name='unsafe_direct_write'")
        XCTAssertTrue(rows.isEmpty)
    }

    func testHistoryPagesKeepProviderOrderAndNewIncomingStaysAhead() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let next = TeamsContinuation(owner: teamsTestCollection, url: URL(string: "https://graph.microsoft.com/v1.0/chats/test-chat/messages?$skiptoken=older")!)
        _ = try await repository.commit(page: TeamsPage(values: [teamsTestMessage("new", id: "new"), teamsTestMessage("middle", id: "middle")], next: next, continuationFailure: nil), collection: teamsTestCollection, baseline: true)
        _ = try await repository.commit(page: TeamsPage(values: [teamsTestMessage("old", id: "old")], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: true)
        let first = try await repository.messages(scope: teamsTestScope, limit: 2)
        XCTAssertEqual(first.values.map(\.id), ["new", "middle"])
        _ = try await repository.commit(page: TeamsPage(values: [teamsTestMessage("fresh", id: "fresh")], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        let older = try await repository.messages(scope: teamsTestScope, before: first.next, limit: 2)
        XCTAssertEqual(older.values.map(\.id), ["old"])
        let latest = try await repository.messages(scope: teamsTestScope, limit: 2)
        XCTAssertEqual(latest.values.map(\.id), ["fresh", "new"])
        await repository.close()
    }
    func testSearchCarriesExactVersionIdentityForHistoricalMatches() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        for message in [teamsTestMessage("match old", modified: 20), teamsTestMessage("match new", modified: 21)] {
            _ = try await repository.commit(page: TeamsPage(values: [message], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        }
        let result = try await repository.search(scope: teamsTestScope, query: "match")
        XCTAssertEqual(result.values.count, 2)
        XCTAssertEqual(result.versionSequences.count, 2)
        XCTAssertEqual(Set(result.versionSequences).count, 2)
        let retained = try await repository.versions(scope: teamsTestScope, messageID: "m1")
        XCTAssertEqual(result.versionSequences, retained.map(\.sequence))
        await repository.close()
    }
    func testPageAndVersionCheckpointRollbackTogether() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let next = TeamsContinuation(owner: teamsTestCollection, url: URL(string: "https://graph.microsoft.com/v1.0/chats/test-chat/messages?$skiptoken=n")!)
        _ = try await repository.commit(page: TeamsPage(values: [teamsTestMessage("original")], next: next, continuationFailure: nil), collection: teamsTestCollection, baseline: true)
        let prior = try await repository.checkpoint(collection: teamsTestCollection)
        do {
            _ = try await repository.commit(page: TeamsPage(values: [teamsTestMessage("must roll back", id: "m2"), teamsTestMessage("invalid", id: "")], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
            XCTFail("Invalid page committed")
        } catch {}
        let after = try await repository.checkpoint(collection: teamsTestCollection)
        let page = try await repository.messages(scope: teamsTestScope, before: nil, limit: 50)
        let jobs = try await repository.pendingProjection(limit: 50)
        XCTAssertEqual(after, prior)
        XCTAssertEqual(page.values.map(\.body), ["original"])
        XCTAssertEqual(jobs.count, 1)
        let ciphertext = try db.execute("SELECT ciphertext FROM \"\(db.configuration.schema)\".teams_versions").joined().joined()
        XCTAssertFalse(ciphertext.contains("original"))
    }

    func testDeletionReopenRetainsOriginalAndRichVersions() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        for message in [teamsTestMessage("retained", metadata: ["importance": "normal"]),
                        teamsTestMessage("retained", modified: 21, metadata: ["importance": "high"]), teamsTestMessage("", modified: 22, deleted: true)] {
            _ = try await repository.commit(page: TeamsPage(values: [message], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        }
        let reopened = TeamsRepository(keyProvider: teamsTestKey)
        try await reopened.open(configuration: db.configuration)
        let versions = try await reopened.versions(scope: teamsTestScope, messageID: "m1", before: nil, limit: 50)
        XCTAssertEqual(versions.count, 3)
        XCTAssertNotNil(versions.first?.message.deletedAt)
        XCTAssertEqual(versions[1].message.metadata["importance"], "high")
        XCTAssertEqual(versions.last?.message.body, "retained")
        let found = try await reopened.search(scope: teamsTestScope, query: "retained", before: nil, limit: 1)
        XCTAssertEqual(found.values.first?.metadata["importance"], "high")
        let more = try await reopened.search(scope: teamsTestScope, query: "retained", before: found.next, limit: 1)
        XCTAssertEqual(more.values.first?.metadata["importance"], "normal")
    }

    func testEqualSourceTimestampRetainsConflictWithoutRollback() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        for message in [teamsTestMessage("first", modified: 20), teamsTestMessage("conflict", modified: 20), teamsTestMessage("older", modified: 19)] {
            _ = try await repository.commit(page: TeamsPage(values: [message], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        }
        let page = try await repository.messages(scope: teamsTestScope, before: nil, limit: 50)
        XCTAssertEqual(page.values.first?.body, "first")
        XCTAssertEqual(page.conflictingMessageIDs, ["m1"])
        let versions = try await repository.versions(scope: teamsTestScope, messageID: "m1", before: nil, limit: 50)
        XCTAssertEqual(versions.count, 3)
    }

    func testMissingKeysNeverInitializeOverExistingVault() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        _ = try await repository.accounts()
        let missing = TeamsRepository(keyProvider: { _, mayCreate in
            XCTAssertFalse(mayCreate)
            throw TeamsFailure.keyUnavailable
        })
        do { try await missing.open(configuration: db.configuration); XCTFail("Missing key recreated") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .keyUnavailable) }
        let restored = TeamsRepository(keyProvider: teamsTestKey)
        try await restored.open(configuration: db.configuration)
        let accounts = try await restored.accounts()
        XCTAssertEqual(accounts.map(\.id), [teamsTestContext.accountID])
    }

    func testPrincipalChangeCannotRebindAccount() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        do {
            try await repository.bindPrincipal(accountID: teamsTestContext.accountID, principal: TeamsPrincipal(tenantID: "55555555-5555-4555-8555-555555555555", userID: teamsTestContext.principal.userID, displayName: "Changed"))
            XCTFail("Account rebound")
        } catch let failure as TeamsFailure { XCTAssertEqual(failure, .principalChanged) }
        let accounts = try await repository.accounts()
        XCTAssertEqual(accounts.first?.verifiedPrincipal, teamsTestContext.principal)
    }

    func testOtherProcessCannotAcquireOrResolveLiveOwner() async throws {
        let db = try database(), first = try await teamsTestRepository(db)
        let second = TeamsRepository(keyProvider: teamsTestKey)
        try await second.open(configuration: db.configuration)
        let lease = try await first.acquireLease(kind: .dispatch, accountID: teamsTestContext.accountID, operationID: UUID())
        do { _ = try await second.acquireLease(kind: .dispatch, accountID: teamsTestContext.accountID, operationID: lease.operationID); XCTFail("Concurrent owner") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .operationBusy) }
        do { try await second.releaseLease(lease); XCTFail("Foreign lease released") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .operationBusy) }
        try await first.releaseLease(lease)
        let next = try await second.acquireLease(kind: .dispatch, accountID: teamsTestContext.accountID, operationID: UUID())
        try await second.releaseLease(next)
    }

    // The durable checkpoint must not rebind even if a caller supplies a typed foreign continuation.
    func testForeignContinuationRetainsPageButLeavesScanIncomplete() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let foreign = TeamsCollection(context: teamsTestContext, kind: .messages(.chat("other-chat")))
        let cursor = TeamsContinuation(owner: foreign, url: URL(string: "https://graph.microsoft.com/v1.0/chats/other-chat/messages?$skiptoken=n")!)
        _ = try await repository.commit(page: TeamsPage(values: [teamsTestMessage("retain despite cursor")], next: cursor, continuationFailure: nil), collection: teamsTestCollection, baseline: true)
        let checkpoint = try await repository.checkpoint(collection: teamsTestCollection)
        XCTAssertNil(checkpoint?.next)
        XCTAssertEqual(checkpoint?.continuationFailure, .invalidContinuation)
        XCTAssertFalse(checkpoint?.complete ?? true)
        let page = try await repository.messages(scope: teamsTestScope, before: nil, limit: 50)
        XCTAssertEqual(page.values.first?.body, "retain despite cursor")
    }

    func testOrphanedDirectoryNeverAllowsNewVaultKeys() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        try await repository.saveConversations([TeamsConversation(scope: teamsTestScope, displayName: "Retained directory", kind: .oneOnOne)],
            collection: TeamsCollection(context: teamsTestContext, kind: .chats), next: nil, failure: nil)
        await repository.close()
        for table in ["teams_metadata", "teams_accounts", "teams_checkpoints"] {
            try db.execute("DELETE FROM \"\(db.configuration.schema)\".\(table)")
        }
        let reopened = TeamsRepository(keyProvider: { _, mayCreate in
            XCTAssertFalse(mayCreate, "Existing encrypted directory must prohibit key initialization")
            throw TeamsFailure.keyUnavailable
        })
        do { try await reopened.open(configuration: db.configuration); XCTFail("Orphaned directory admitted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .keyUnavailable) }
        XCTAssertEqual(try db.execute("SELECT count(*) FROM \"\(db.configuration.schema)\".teams_directory")[0][0], "1")
        XCTAssertEqual(try db.execute("SELECT count(*) FROM \"\(db.configuration.schema)\".teams_metadata")[0][0], "0")
    }
}

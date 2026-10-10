import XCTest
import Foundation
@testable import MakoshCore

final class MessageArchiveStoreTests: XCTestCase {
    private let key = Data(repeating: 0x31, count: 32)
    private func database() throws -> PostgresTestDatabase {
        let database = try PostgresTestDatabase()
        addTeardownBlock { try database.cleanup() }
        return database
    }
    private func store(_ db: PostgresTestDatabase) throws -> MessageArchiveStore {
        try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { _, _ in self.key }
    }
    private func observation(_ text: String, account: String = "account", chat: String = "chat", message: String = "cloud:1") -> MessageArchiveObservation {
        MessageArchiveObservation(identity: MessageArchiveIdentity(service: "telegram", accountID: account,
            conversationID: chat, messageID: message), observedAt: Date(timeIntervalSince1970: 10), source: .synthetic,
            event: .message(MessageArchiveContent(date: Date(timeIntervalSince1970: 1), text: text, author: "author", isOutgoing: false)))
    }
    private func records(_ store: MessageArchiveStore, account: String = "account", chat: String = "chat") throws -> [MessageArchiveRecord] {
        try store.records(service: "telegram", accountID: account, conversationID: chat)
    }

    func testInvalidObservationAndOversizeBatchRollBackEarlierValidRecords() throws {
        let db = try database(), archive = try store(db)
        let invalid = observation("invalid", account: "")
        XCTAssertThrowsError(try archive.append([observation("valid"), invalid]))
        XCTAssertTrue(try archive.records().isEmpty)
        XCTAssertEqual(try db.execute("SELECT count(*) FROM \"\(db.schema)\".archive_receipts")[0][0], "0")
        XCTAssertThrowsError(try archive.append(Array(repeating: observation("bound"), count: 1001)))
        XCTAssertThrowsError(try archive.append([observation(String(repeating: "x", count: 4 * 1024 * 1024))]))
        XCTAssertTrue(try archive.records().isEmpty)
    }

    func testRestartOriginalEditDeletionAndAToBToAStayAppendOnly() throws {
        let db = try database(), first = try store(db)
        let a = observation("original"), b = observation("edit")
        XCTAssertEqual(try first.append([a,a]), 1)
        XCTAssertEqual(try first.append([observation("original")]), 0)
        XCTAssertEqual(try first.append([b,observation("original")]), 2)
        let deleted = MessageArchiveObservation(identity: a.identity, source: .update, event: .deleted)
        XCTAssertEqual(try first.append([deleted]), 1)
        let reopened = try store(db), rows = try records(reopened)
        XCTAssertEqual(rows.count, 4); XCTAssertEqual(rows.first?.observation.event, .deleted)
        XCTAssertEqual(rows.last?.observation.event, a.event)
        XCTAssertEqual(rows.map(\.sequence), rows.map(\.sequence).sorted(by: >))
        let page = try reopened.records(service: "telegram", accountID: "account", conversationID: "chat", before: rows[1].sequence, limit: 1)
        XCTAssertEqual(page.first?.sequence, rows[2].sequence)
        XCTAssertThrowsError(try reopened.records(service: "telegram", accountID: "account", conversationID: "chat", limit: 201))
    }

    func testNoopObservationReceiptPreventsDelayedRetryBecomingNewVersion() throws {
        let db = try database(), archive = try store(db)
        let a = observation("A"), duplicate = observation("A"), b = observation("B")
        XCTAssertEqual(try archive.append([a,duplicate,b]), 2)
        XCTAssertEqual(try archive.append([duplicate]), 0)
        let conflicting = MessageArchiveObservation(id: duplicate.id, identity: duplicate.identity,
            observedAt: duplicate.observedAt, source: duplicate.source, event: b.event)
        XCTAssertThrowsError(try archive.append([conflicting]))
        XCTAssertEqual(try records(archive).count, 2)
    }

    func testExactUTF8AccountChatAndNamespaceIdentityIsolation() throws {
        let db = try database(), archive = try store(db)
        let observations = [observation("é"), observation("e\u{301}"), observation("other", account: "other"),
            observation("other", chat: "other"), observation("namespace", message: "local:1"),
            observation("unicode", account: "é"), observation("unicode", account: "e\u{301}")]
        XCTAssertEqual(try archive.append(observations), observations.count)
        XCTAssertEqual(try records(archive).count, 3)
        XCTAssertEqual(try records(archive, account: "other").count, 1)
        XCTAssertEqual(try records(archive, chat: "other").count, 1)
        XCTAssertEqual(try archive.records().count, observations.count)
        XCTAssertEqual(try records(archive, account: "é").count, 1)
        XCTAssertEqual(try records(archive, account: "e\u{301}").count, 1)
        let stored = try db.execute("SELECT ciphertext,account_token,stream_token,message_token FROM \"\(db.schema)\".archive_events")
        XCTAssertFalse(stored.joined().joined().contains("namespace"))
    }

    func testMissingWrongAndShortKeysNeverPermitCreationOnExistingEmptyVault() throws {
        let db = try database()
        var creation: [Bool] = []
        _ = try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { _, allowed in creation.append(allowed); return self.key }
        XCTAssertEqual(creation, [true])
        for candidate in [Data(), Data(repeating: 2, count: 32)] {
            XCTAssertThrowsError(try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { _, allowed in
                XCTAssertFalse(allowed); return candidate
            })
        }
        XCTAssertThrowsError(try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { _, allowed in
            XCTAssertFalse(allowed); throw MessageArchiveError.keyUnavailable
        })
        XCTAssertEqual(try records(store(db)).count, 0)
    }

    func testFutureSchemaFailsWithoutChangingRowsOrCallingKeyProvider() throws {
        let db = try database(), archive = try store(db)
        _ = try archive.append([observation("original")])
        let before = try db.execute("SELECT ciphertext FROM \"\(db.schema)\".archive_events")
        try db.execute("UPDATE \"\(db.schema)\".archive_metadata SET version=999")
        XCTAssertThrowsError(try records(archive))
        XCTAssertThrowsError(try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { _, _ in XCTFail("Future schema requested key"); return self.key })
        XCTAssertEqual(try db.execute("SELECT ciphertext FROM \"\(db.schema)\".archive_events"), before)
    }

    func testBatchRollbackAndRewriteTriggers() throws {
        let db = try database(), archive = try store(db)
        try db.execute("CREATE FUNCTION \"\(db.schema)\".reject_archive() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic failure'; END $$")
        try db.execute("CREATE TRIGGER reject_archive BEFORE INSERT ON \"\(db.schema)\".archive_events FOR EACH ROW EXECUTE FUNCTION \"\(db.schema)\".reject_archive()")
        let value = observation("never committed")
        XCTAssertThrowsError(try archive.append([value]))
        XCTAssertTrue(try records(archive).isEmpty)
        XCTAssertEqual(try db.execute("SELECT count(*) FROM \"\(db.schema)\".archive_receipts")[0][0], "0")
        try db.execute("DROP TRIGGER reject_archive ON \"\(db.schema)\".archive_events")
        XCTAssertEqual(try archive.append([value]), 1)
        for sql in ["UPDATE", "DELETE", "TRUNCATE"] {
            let statement = sql == "UPDATE" ? "UPDATE \"\(db.schema)\".archive_events SET ciphertext='changed'" : sql == "DELETE" ? "DELETE FROM \"\(db.schema)\".archive_events" : "TRUNCATE \"\(db.schema)\".archive_events"
            XCTAssertThrowsError(try db.execute(statement))
        }
        XCTAssertEqual(try records(archive).count, 1)
    }

    func testCiphertextTamperAndSequenceSubstitutionFailAuthentication() throws {
        let db = try database(), archive = try store(db)
        _ = try archive.append([observation("A"), observation("B")])
        try db.execute("ALTER TABLE \"\(db.schema)\".archive_events DISABLE TRIGGER archive_no_rewrite")
        let rows = try db.execute("SELECT sequence,ciphertext FROM \"\(db.schema)\".archive_events ORDER BY sequence")
        // Base64 ciphertext has no SQL quote characters; only synthetic test ciphertext is substituted.
        try db.execute("UPDATE \"\(db.schema)\".archive_events SET ciphertext='\(rows[0][1])' WHERE sequence=\(rows[1][0])")
        XCTAssertThrowsError(try records(archive))
        try db.execute("UPDATE \"\(db.schema)\".archive_events SET ciphertext='invalid-base64' WHERE sequence=\(rows[1][0])")
        XCTAssertThrowsError(try records(archive))
    }

    func testIndependentConnectionsSerializeIdenticalAppend() throws {
        let db = try database(), first = try store(db), second = try store(db)
        let value = observation("concurrent")
        final class Work: @unchecked Sendable {
            let store: MessageArchiveStore
            let value: MessageArchiveObservation
            var result: Result<Int, Error>?
            init(_ store: MessageArchiveStore, _ value: MessageArchiveObservation) { self.store = store; self.value = value }
        }
        let work = [Work(first,value),Work(second,value)], group = DispatchGroup()
        for item in work {
            group.enter()
            DispatchQueue.global().async { item.result = Result { try item.store.append([item.value]) }; group.leave() }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let counts = try work.map { try XCTUnwrap($0.result).get() }
        XCTAssertEqual(counts.sorted(), [0,1]); XCTAssertEqual(try records(first).count, 1)
    }
}

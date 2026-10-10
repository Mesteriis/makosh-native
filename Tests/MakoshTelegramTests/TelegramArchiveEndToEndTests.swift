import XCTest
import Foundation
import CPostgres
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

// Created outside MainActor: Postbox executes transaction bodies on its own queue.
private func captureEndToEnd(_ postbox: Postbox, peer: PeerId, deletedID: MessageId) -> Signal<[MakoshMessageJournalEntry], NoError> {
    postbox.transaction { transaction -> [MakoshMessageJournalEntry] in
        func message(_ number: Int32, _ text: String) -> StoreMessage {
            StoreMessage(id: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: number),
                globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: number,
                flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
                authorId: peer, text: text, attributes: [], media: [])
        }
        _ = transaction.addMessages((1...55).map { message(Int32($0), "original-\($0)") }, location: .Random)
        transaction.updateMessage(deletedID) { _ in .update(message(1,"edited")) }
        transaction.deleteMessages([deletedID], forEachMedia: nil)
        XCTAssertNil(transaction.getMessage(deletedID))
        do { return try transaction.makoshArchiveJournal(limit: 100) }
        catch { XCTFail("Synthetic central capture failed"); return [] }
    }
}
private func readEndToEnd(_ postbox: Postbox, deletedID: MessageId? = nil) -> Signal<[MakoshMessageJournalEntry], NoError> {
    postbox.transaction { transaction -> [MakoshMessageJournalEntry] in
        if let deletedID { XCTAssertNil(transaction.getMessage(deletedID)) }
        do { return try transaction.makoshArchiveJournal(limit: 100) }
        catch { XCTFail("Synthetic journal read failed"); return [] }
    }
}
private actor EndToEndArchiveRepository: TelegramArchiveRepository {
    private let store: MessageArchiveStore
    init(connectionString: String, schema: String, key: Data) throws {
        store = try MessageArchiveStore(connectionString: connectionString, schema: schema) { _, _ in key }
    }
    func append(_ observations: [MessageArchiveObservation]) throws -> Int { try store.append(observations) }
    func records(before: Int64?) throws -> [MessageArchiveRecord] { try store.records(before: before) }
}

@MainActor private final class EndToEndPostboxJournal: TelegramArchiveJournal {
    let accountID: Int64 = 1234
    let postbox: Postbox
    var acknowledgementCount = 0
    init(_ postbox: Postbox) { self.postbox = postbox }
    func read(receive: @escaping @MainActor (Result<[TelegramArchiveJournalItem], TelegramArchiveReadError>) -> Void) -> Disposable {
        let account = accountID
        return (telegramArchiveJournalRead(postbox: postbox) |> take(1) |> deliverOnMainQueue).start(next: { result in
            receive(result.map { $0.map { telegramArchiveItem($0, accountID: account) } })
        })
    }
    func acknowledge(sequences: [Int64], receive: @escaping @MainActor (Bool) -> Void) -> Disposable {
        acknowledgementCount += 1
        return (telegramArchiveJournalAcknowledge(postbox: postbox, sequences: sequences) |> take(1) |> deliverOnMainQueue).start(next: receive)
    }
}

@MainActor final class TelegramArchiveEndToEndTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) async -> T {
        let completed = expectation(description: "Synthetic Postbox transaction completes")
        var result: T?
        let disposable = (signal |> take(1) |> deliverOnMainQueue).start(next: {
            result = $0; completed.fulfill()
        })
        defer { disposable.dispose() }
        await fulfillment(of: [completed], timeout: 20)
        // Raw engine objects stay on MainActor, rather than crossing a sending
        // continuation whose result would require an unsafe Sendable promise.
        return result!
    }
    private func sql(_ db: OpaquePointer, _ text: String) throws -> [[String]] {
        guard let result = PQexec(db, text) else { throw MessageArchiveError.database }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_COMMAND_OK || PQresultStatus(result) == PGRES_TUPLES_OK else { throw MessageArchiveError.database }
        return (0..<PQntuples(result)).map { row in (0..<PQnfields(result)).map { column in String(cString: PQgetvalue(result,row,column)) } }
    }
    private func eventually(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testEncryptedPostboxCaptureSurvivesRealDeletionAndPostgresFailureAcrossReopen() async throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !dsn.isEmpty else {
            throw MessageArchiveError.database
        }
        let schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard schema.utf8.count == 44, schema.hasPrefix("makosh_test_"),
              schema.dropFirst(12).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw MessageArchiveError.invalid }
        guard let db = PQconnectdb(dsn) else { throw MessageArchiveError.database }
        guard PQstatus(db) == CONNECTION_OK else { PQfinish(db); throw MessageArchiveError.database }
        defer { PQfinish(db) }
        PQsetNoticeProcessor(db, { _, _ in }, nil)
        _ = try sql(db, "SET statement_timeout TO '15s'")
        defer { _ = try? sql(db, "DROP SCHEMA \"\(schema)\" CASCADE") }
        let key = Data(repeating: 0x5a, count: 32)
        let repository = try EndToEndArchiveRepository(connectionString: dsn, schema: schema, key: key)
        _ = try sql(db, "CREATE FUNCTION \"\(schema)\".reject_test_archive() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic failure'; END $$")
        _ = try sql(db, "CREATE TRIGGER reject_test_archive BEFORE INSERT ON \"\(schema)\".archive_events FOR EACH ROW EXECUTE FUNCTION \"\(schema)\".reject_test_archive()")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let boxKey = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 1, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 2, count: 16)))
        let opened = expectation(description: "Encrypted synthetic Postbox opens")
        var postbox: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: boxKey, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false) |> deliverOnMainQueue).start(next: {
                if case let .postbox(box) = $0 { postbox = box; opened.fulfill() }
            })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let source = try XCTUnwrap(postbox)
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(987654))
        let deletedID = MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1)
        let captured = await value(captureEndToEnd(source, peer: peer, deletedID: deletedID))
        XCTAssertGreaterThan(captured.count, 55)
        let journal = EndToEndPostboxJournal(source), controller = TelegramArchiveController()
        controller.configure(repository: repository); controller.bind(journal: journal)
        defer { controller.bind(journal: nil) }
        await eventually { controller.error != nil && !controller.isArchiving }
        XCTAssertEqual(journal.acknowledgementCount, 0)
        let pending = await value(readEndToEnd(source))
        XCTAssertEqual(pending.map(\.eventID), captured.map(\.eventID))
        XCTAssertEqual(try sql(db,"SELECT count(*) FROM \"\(schema)\".archive_events")[0][0], "0")
        _ = try sql(db,"DROP TRIGGER reject_test_archive ON \"\(schema)\".archive_events")
        controller.retry()
        await eventually { journal.acknowledgementCount == 1 && !controller.isArchiving }
        controller.bind(journal: nil)
        let remaining = await value(readEndToEnd(source, deletedID: deletedID))
        XCTAssertTrue(remaining.isEmpty)
        let independent = try MessageArchiveStore(connectionString: dsn, schema: schema) { _, allowed in
            XCTAssertFalse(allowed); return key
        }
        let records = try independent.records()
        XCTAssertGreaterThan(records.count, 50)
        let first = records.filter { $0.observation.identity.messageID == "\(Namespaces.Message.Cloud):1" }
        let texts = first.compactMap { record -> String? in
            if case let .message(content) = record.observation.event { return content.text }; return nil
        }
        XCTAssertTrue(texts.contains("original-1")); XCTAssertTrue(texts.contains("edited"))
        XCTAssertTrue(first.contains { $0.observation.event == .removedFromSource })
        XCTAssertEqual(Set(records.map { $0.observation.identity.accountID }), ["1234"])
        XCTAssertEqual(try independent.append(captured.flatMap { telegramArchiveItem($0, accountID: 1234).observations }), 0)
        XCTAssertEqual(try independent.records().count, records.count)
        XCTAssertFalse(try sql(db,"SELECT ciphertext FROM \"\(schema)\".archive_events").joined().joined().contains("original-1"))
    }
}

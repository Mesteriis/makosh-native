import Foundation
import XCTest
@testable import MakoshCore

final class AIAccessPolicyTests: XCTestCase {
    private let key = Data(repeating: 0x65, count: 32)
    private let chat = AIAccessScope.conversation(service: "telegram", accountID: "synthetic-account", conversationID: "synthetic-chat")
    private let otherChat = AIAccessScope.conversation(service: "telegram", accountID: "synthetic-account", conversationID: "other-chat")
    private let mailbox = AIAccessScope.mailAccount(accountID: "synthetic-mailbox")

    private func store() throws -> (PostgresTestDatabase, MessageArchiveStore) {
        let db = try PostgresTestDatabase()
        addTeardownBlock { try db.cleanup() }
        let key = key
        return (db, try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { _, _ in key })
    }

    func testDefaultIsDisabled() throws {
        let (_, store) = try store()
        XCTAssertFalse(try store.aiAccessEnabled(chat))
        XCTAssertFalse(try store.aiAccessEnabled(mailbox))
        XCTAssertTrue(try store.enabledAIScopes().isEmpty)
    }

    func testSetAndListScopes() throws {
        let (_, store) = try store()
        try store.setAIAccess(chat, enabled: true)
        try store.setAIAccess(mailbox, enabled: true)
        XCTAssertEqual(Set(try store.enabledAIScopes()), [chat, mailbox])
        try store.setAIAccess(chat, enabled: false)
        XCTAssertEqual(try store.enabledAIScopes(), [mailbox])
        XCTAssertFalse(try store.aiAccessEnabled(chat))
    }

    func testScopesAreIndependent() throws {
        let (_, store) = try store()
        try store.setAIAccess(chat, enabled: true)
        XCTAssertTrue(try store.aiAccessEnabled(chat))
        XCTAssertFalse(try store.aiAccessEnabled(otherChat))
        XCTAssertFalse(try store.aiAccessEnabled(.mailAccount(accountID: "synthetic-account")))
    }

    func testPolicyIsEncrypted() throws {
        let (db, store) = try store()
        try store.setAIAccess(chat, enabled: true)
        let rows = try db.execute("SELECT scope_token,ciphertext FROM \"\(db.schema)\".archive_ai_policy")
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows.flatMap { $0 }.joined().contains("synthetic-chat"))
    }

    func testHeaderWithoutAIPolicyCountIsAccepted() throws {
        var counts = Dictionary(uniqueKeysWithValues: ArchiveBackupTable.allCases.map { ($0.rawValue, Int64(0)) })
        counts[ArchiveBackupTable.metadata.rawValue] = 1
        counts[ArchiveBackupTable.aiPolicies.rawValue] = nil
        let header = ArchiveBackupHeader(
            vaultID: UUID(), rootKey: Data(repeating: 1, count: 32), partCount: 1, databaseBytes: 10,
            databaseHash: String(repeating: "a", count: 64), counts: counts, objectCount: 0, objectBytes: 0, sourceStorageID: nil)
        XCTAssertNoThrow(try header.validate())
        XCTAssertEqual(header.normalizedCounts[ArchiveBackupTable.aiPolicies.rawValue], 0)
    }
}

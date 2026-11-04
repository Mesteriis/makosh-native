import Foundation
import XCTest
@testable import MakoshCore

final class MessageArchiveIndexSourceTests: XCTestCase {
    private let key = Data(repeating: 0x66, count: 32)

    private func fixture() throws -> (MessageArchiveStore, MessageArchiveIndexSource) {
        let db = try PostgresTestDatabase()
        addTeardownBlock { try db.cleanup() }
        let key = key
        let store = try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { _, _ in key }
        let source = try MessageArchiveIndexSource(connectionString: db.connectionString, schema: db.schema) { _, _ in key }
        return (store, source)
    }
    private func message(
        _ service: String, chat: String, id: String, text: String, author: String? = "peer", outgoing: Bool = false, account: String = "acc"
    ) -> MessageArchiveObservation {
        .init(
            identity: .init(service: service, accountID: account, conversationID: chat, messageID: id), source: .synthetic,
            event: .message(
                .init(date: Date(timeIntervalSince1970: 100), text: text, author: "Peer", authorID: author, isOutgoing: outgoing)))
    }

    func testItemsAfterAscendingAndBounded() async throws {
        let (store, source) = try fixture()
        _ = try store.append((1...5).map { message("telegram", chat: "c", id: "\($0)", text: "m\($0)") })
        let first = try await source.items(after: 0, limit: 2)
        XCTAssertEqual(first.map(\.text), ["m1", "m2"])
        let rest = try await source.items(after: try XCTUnwrap(first.last?.sequence), limit: 200)
        XCTAssertEqual(rest.map(\.text), ["m3", "m4", "m5"])
        XCTAssertEqual(source.name, "archive")
        do {
            _ = try await source.items(after: 0, limit: 0)
            XCTFail("zero limit accepted")
        } catch {}
    }

    func testMailEventsSkipped() async throws {
        let (store, source) = try fixture()
        _ = try store.append([
            message("mail", chat: "INBOX", id: "1", text: "outgoing letter"), message("teams", chat: "t", id: "2", text: "hi"),
        ])
        let items = try await source.items(after: 0, limit: 200)
        XCTAssertEqual(items.map(\.identity.service), ["teams"])
    }

    func testDeletionBecomesRemoved() async throws {
        let (store, source) = try fixture()
        let original = message("whatsapp", chat: "w", id: "1", text: "hello")
        _ = try store.append([original, .init(identity: original.identity, source: .synthetic, event: .deleted)])
        let items = try await source.items(after: 0, limit: 200)
        XCTAssertEqual(items.map(\.removed), [false, true])
        XCTAssertEqual(items.last?.text, "")
    }

    func testScopeBackfillOnlyThatConversation() async throws {
        let (store, source) = try fixture()
        _ = try store.append([
            message("telegram", chat: "a", id: "1", text: "a1"), message("telegram", chat: "b", id: "2", text: "b1"),
            message("telegram", chat: "a", id: "3", text: "a2"),
        ])
        let scope = AIAccessScope.conversation(service: "telegram", accountID: "acc", conversationID: "a")
        let items = try await source.items(in: scope, after: 0, limit: 200)
        XCTAssertEqual(items.map(\.text), ["a1", "a2"])
        XCTAssertTrue(items.allSatisfy { $0.scope == scope })
        let mail = try await source.items(in: .mailAccount(accountID: "acc"), after: 0, limit: 200)
        XCTAssertTrue(mail.isEmpty)
    }

    func testScopeBackfillReturnsLatestStateOnly() async throws {
        let (store, source) = try fixture()
        let edited = message("telegram", chat: "a", id: "1", text: "old text")
        let deleted = message("telegram", chat: "a", id: "2", text: "deleted text")
        _ = try store.append([edited, deleted, message("telegram", chat: "a", id: "3", text: "kept")])
        _ = try store.append([
            .init(
                identity: edited.identity, source: .synthetic,
                event: .message(
                    .init(date: Date(timeIntervalSince1970: 100), text: "new text", author: "Peer", authorID: "peer", isOutgoing: false))),
            .init(identity: deleted.identity, source: .synthetic, event: .deleted),
        ])
        let scope = AIAccessScope.conversation(service: "telegram", accountID: "acc", conversationID: "a")
        let items = try await source.items(in: scope, after: 0, limit: 200)
        XCTAssertEqual(items.map(\.text), ["kept", "new text"])
        XCTAssertFalse(items.contains { $0.removed })
        let tail = try await source.items(in: scope, after: try XCTUnwrap(items.first?.sequence), limit: 200)
        XCTAssertEqual(tail.map(\.text), ["new text"])
    }

    func testAuthorMapping() async throws {
        let (store, source) = try fixture()
        _ = try store.append([
            message("telegram", chat: "c", id: "1", text: "in", author: "42"),
            message("telegram", chat: "c", id: "2", text: "out", author: "7", outgoing: true),
            message("teams", chat: "t", id: "3", text: "anon", author: nil),
        ])
        let items = try await source.items(after: 0, limit: 200)
        XCTAssertEqual(items[0].author, ServiceIdentity(service: "telegram", accountID: "acc", externalID: "42"))
        XCTAssertFalse(items[0].isOutgoing)
        XCTAssertTrue(items[1].isOutgoing)
        XCTAssertNil(items[2].author)
    }
}

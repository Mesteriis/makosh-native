import XCTest
@testable import MakoshCore

final class SourceNoteTests: XCTestCase {
    func note(id: UUID = UUID(), text: String = "Meeting reference") -> ContactNote {
        .init(id: id, text: text,
              source: .init(identity: .init(service: "telemost", accountID: "synthetic", externalID: "123"), fetchedAt: Date(timeIntervalSince1970: 100)))
    }
    func testSourceNoteRetryIsSemanticNoOp() throws {
        let db = try PostgresTestDatabase(); defer { try? db.cleanup() }; let store = try db.makeStore()
        let id = try store.createContact(draft: .init(displayName: "Synthetic")), value = note()
        XCTAssertEqual(try store.addSourceNote(contactID: id, note: value), id)
        let first = try XCTUnwrap(store.contacts().first)
        XCTAssertEqual(try store.addSourceNote(contactID: id, note: value), id)
        let second = try XCTUnwrap(store.contacts().first)
        XCTAssertEqual(second.notes.count, 1); XCTAssertEqual(first.revision, second.revision)
        XCTAssertEqual(first.events, second.events); XCTAssertTrue(second.identities.isEmpty)
    }
    func testConflictingNoteIDFailsClosed() throws {
        let db = try PostgresTestDatabase(); defer { try? db.cleanup() }; let store = try db.makeStore()
        let id = try store.createContact(draft: .init(displayName: "Synthetic")), value = note(text: "\u{e9}")
        _ = try store.addSourceNote(contactID: id, note: value)
        var forged = value; forged.text = "e\u{301}"
        XCTAssertThrowsError(try store.addSourceNote(contactID: id, note: forged))
        forged = value; forged.source.identity.accountID = "another"
        XCTAssertThrowsError(try store.addSourceNote(contactID: id, note: forged))
        XCTAssertEqual(try store.contacts().first?.notes.count, 1)
    }
    func testSourceNoteSurvivesMergeAndUndo() throws {
        let db = try PostgresTestDatabase(); defer { try? db.cleanup() }; let store = try db.makeStore()
        let a = try store.createContact(draft: .init(displayName: "A")), b = try store.createContact(draft: .init(displayName: "B"))
        let value = note(); _ = try store.addSourceNote(contactID: b, note: value)
        let merge = try store.merge(survivorID: a, removedID: b)
        XCTAssertEqual(try store.addSourceNote(contactID: b, note: value), a)
        try store.undoMerge(id: merge)
        XCTAssertEqual(try store.contacts().first { $0.id == b }?.notes.map(\.id), [value.id])
    }
    func testLaterNoteBlocksStaleUndo() throws {
        let db = try PostgresTestDatabase(); defer { try? db.cleanup() }; let store = try db.makeStore()
        let a = try store.createContact(draft: .init(displayName: "A")), b = try store.createContact(draft: .init(displayName: "B"))
        let merge = try store.merge(survivorID: a, removedID: b)
        _ = try store.addSourceNote(contactID: a, note: note())
        XCTAssertThrowsError(try store.undoMerge(id: merge))
    }
}

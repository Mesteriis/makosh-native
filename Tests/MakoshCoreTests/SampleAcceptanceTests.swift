import XCTest
@testable import MakoshCore

final class SampleAcceptanceTests: XCTestCase {
    func testShippedSyntheticExampleMergeUndoAndReopen() throws {
        let database = try PostgresTestDatabase()
        defer { try? database.cleanup() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = try Data(contentsOf: root.appendingPathComponent("Examples/contacts.synthetic.json"))
        let store = try database.makeStore()
        XCTAssertEqual(try store.importJSON(data: sample), ImportResult(created: 3, updated: 0))
        XCTAssertEqual(try store.importJSON(data: sample), ImportResult(created: 0, updated: 0))
        let candidates = try store.duplicateCandidates()
        XCTAssertEqual(candidates.count, 1, "The same-name third person must not become a merge candidate")
        let candidate = try XCTUnwrap(candidates.first)
        let journalID = try store.merge(survivorID: candidate.firstID, removedID: candidate.secondID)
        let merged = try XCTUnwrap(store.contact(id: candidate.firstID))
        XCTAssertEqual(merged.identities.count, 2)
        XCTAssertEqual(merged.notes.count, 2)
        XCTAssertEqual(merged.emails.count, 2)
        XCTAssertEqual(try store.importJSON(data: sample).created, 0)
        XCTAssertEqual(try store.contacts().count, 2)
        try store.undoMerge(id: journalID)
        let reopened = try database.makeStore()
        XCTAssertEqual(try reopened.contacts().count, 3)
        XCTAssertEqual(try reopened.duplicateCandidates().count, 1)
        XCTAssertNotNil(try reopened.mergeHistory().first?.undoneAt)
        let restored = try XCTUnwrap(reopened.contact(id: candidate.firstID))
        var edit = restored.draft; edit.organization = "Ручная компания"
        try reopened.updateContact(id: restored.id, draft: edit)
        _ = try reopened.importJSON(data: sample)
        XCTAssertEqual(try reopened.contact(id: restored.id)?.organization, "Ручная компания")
    }
}

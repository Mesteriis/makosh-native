import Foundation
import XCTest
@testable import MakoshCore

final class PersonStoreTests: XCTestCase {
    private var database: PostgresTestDatabase!
    override func setUpWithError() throws { database = try PostgresTestDatabase() }
    override func tearDownWithError() throws { try database?.cleanup() }
    private func document(_ contacts: [ImportedPerson], account: String = "a", time: TimeInterval = 100) -> ImportDocument {
        ImportDocument(
            source: ImportSource(service: "test", accountID: account), fetchedAt: Date(timeIntervalSince1970: time), contacts: contacts)
    }
    private func imported(
        _ id: String, name: String = "Name", emails: [String] = [], phones: [String] = [], tags: [String] = [], notes: [String] = []
    ) -> ImportedPerson {
        ImportedPerson(externalID: id, displayName: name, phones: phones, emails: emails, tags: tags, notes: notes)
    }
    private final class ConcurrentStores: @unchecked Sendable {
        let stores: [PersonStore]
        let lock = NSLock()
        var errors: [Error] = []
        init(_ stores: [PersonStore]) { self.stores = stores }
        func write(_ index: Int) {
            do { _ = try stores[index % 2].createPerson(draft: PersonDraft(displayName: "Person \(index)")) } catch {
                lock.lock()
                errors.append(error)
                lock.unlock()
            }
        }
    }
    func testConcurrentConnectionsDoNotLoseWrites() throws {
        let workers = ConcurrentStores([try database.makeStore(), try database.makeStore()])
        DispatchQueue.concurrentPerform(iterations: 20) { workers.write($0) }
        XCTAssertTrue(workers.errors.isEmpty)
        XCTAssertEqual(try workers.stores[0].persons().count, 20)
    }
    func testInvalidSchemaNamesFailBeforeConnecting() throws {
        for schema in ["", "Upper", "bad-name", "a;DROP SCHEMA public", "é", String(repeating: "a", count: 64)] {
            XCTAssertThrowsError(try PersonStore(connectionString: database.connectionString, schema: schema)) { error in
                guard case StoreError.invalid = error else { return XCTFail("Expected schema validation error") }
            }
        }
    }
    func testConnectionErrorsDoNotRevealConnectionDetails() throws {
        let syntheticDSN = "host=127.0.0.1 port=1 dbname=private-test-marker user=test password=private-password"
        XCTAssertThrowsError(try PersonStore(connectionString: syntheticDSN, schema: database.schema)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-test-marker"))
            XCTAssertFalse(error.localizedDescription.contains("private-password"))
            XCTAssertFalse(error.localizedDescription.contains("127.0.0.1"))
        }
    }
    func testFutureSchemaFailsClosedWithoutWritingState() throws {
        let store = try database.makeStore()
        _ = try store.createPerson(draft: PersonDraft(displayName: "Preserved"))
        let before = try database.contactStoreSnapshot()
        try database.execute("UPDATE contact_store_meta SET schema_version=3 WHERE id=1")
        XCTAssertThrowsError(try database.makeStore()) { error in
            guard case StoreError.unsupportedSchema(3) = error else { return XCTFail("Wrong error type") }
        }
        XCTAssertThrowsError(try store.persons())
        XCTAssertThrowsError(try store.createPerson(draft: PersonDraft(displayName: "Blocked")))
        XCTAssertEqual(try database.contactStoreSnapshot(), before)
        XCTAssertEqual(try database.execute("SELECT schema_version::text FROM contact_store_meta WHERE id=1"), [["3"]])
    }
    func testWritesOnlyTouchChangedContactRows() throws {
        let store = try database.makeStore()
        let first = try store.createPerson(draft: PersonDraft(displayName: "First"))
        let second = try store.createPerson(draft: PersonDraft(displayName: "Second"))
        let untouched = try database.execute("SELECT xmin::text FROM contact_records WHERE id='\(second.uuidString)'")
        try store.addNote(contactID: first, text: "Only the first row changes")
        XCTAssertEqual(try database.execute("SELECT xmin::text FROM contact_records WHERE id='\(second.uuidString)'"), untouched)
        XCTAssertEqual(try store.person(id: first)?.notes.count, 1)
    }
    func testPersistenceAndIndependentStoresReloadBeforeWrites() throws {
        let first = try database.makeStore(), second = try database.makeStore()
        let id = try first.createPerson(draft: PersonDraft(displayName: "One"))
        _ = try second.createPerson(draft: PersonDraft(displayName: "Two"))
        try first.addNote(contactID: id, text: "Kept")
        let reopened = try database.makeStore()
        XCTAssertEqual(try reopened.persons().count, 2)
        XCTAssertEqual(try reopened.person(id: id)?.notes.first?.text, "Kept")
    }
    func testAccountIsolationAndIdempotentReimport() throws {
        let store = try database.makeStore()
        let doc = document([imported("1", emails: ["one@example.org"], notes: ["Note"])])
        XCTAssertEqual(try store.importDocument(doc), ImportResult(created: 1, updated: 0))
        let before = try store.persons()
        XCTAssertEqual(try store.importDocument(doc), ImportResult(created: 0, updated: 0))
        XCTAssertEqual(try store.persons(), before)
        _ = try store.importDocument(document([imported("1", name: "Other")], account: "b"))
        XCTAssertEqual(try store.persons().count, 2)
    }
    func testUnicodeByteDistinctSourceIDsAndAccountsRemainSeparateAfterPersistence() throws {
        let store = try database.makeStore()
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        // Swift String's canonical equality is unsuitable for external source identifiers.
        _ = try store.importDocument(document([imported(composed, name: "Composed ID"), imported(decomposed, name: "Decomposed ID")]))
        _ = try store.importDocument(document([imported("same", name: "Composed account")], account: composed))
        _ = try store.importDocument(document([imported("same", name: "Decomposed account")], account: decomposed))
        let reopened = try database.makeStore()
        XCTAssertEqual(try reopened.persons().count, 4)
        XCTAssertEqual(
            try reopened.importDocument(document([imported(composed, name: "Composed ID"), imported(decomposed, name: "Decomposed ID")])),
            ImportResult(created: 0, updated: 0))
        XCTAssertEqual(Set(try reopened.persons().flatMap(\.identities).map(\.id)).count, 4)
    }
    func testManualOverridesAndRemovedArraysRemainSuppressedWithProvenance() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1", emails: ["old@example.org"], phones: ["123456"], tags: ["Imported"])]))
        var contact = try XCTUnwrap(store.persons().first)
        var draft = contact.draft
        draft.displayName = "Manual"
        draft.emails = []
        draft.phones = []
        draft.tags = []
        try store.updatePerson(id: contact.id, draft: draft)
        _ = try store.importDocument(
            document([imported("1", name: "Remote", emails: ["new@example.org"], phones: ["987654"], tags: ["New"])], time: 200))
        contact = try XCTUnwrap(store.person(id: contact.id))
        XCTAssertEqual(contact.displayName, "Manual")
        XCTAssertTrue(contact.emails.isEmpty)
        XCTAssertTrue(contact.phones.isEmpty)
        XCTAssertTrue(contact.tags.isEmpty)
        XCTAssertTrue(contact.observations.contains { $0.field == "emails" && $0.value == "new@example.org" })
    }
    func testOldImportDoesNotOverwriteNewerStateOrGrowHistory() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1", name: "New")], time: 200))
        let before = try store.persons()
        XCTAssertEqual(
            try store.importDocument(document([imported("1", name: "Old", notes: ["Old note"])], time: 100)),
            ImportResult(created: 0, updated: 0))
        XCTAssertEqual(try store.persons(), before)
    }
    func testImportValidationIsAtomicAndNextTransactionWorks() throws {
        let store = try database.makeStore()
        XCTAssertThrowsError(try store.importDocument(document([imported("1"), imported("2", name: " ")])))
        XCTAssertTrue(try store.persons().isEmpty)
        XCTAssertThrowsError(try store.importDocument(document([imported("1"), imported("1")])))
        XCTAssertTrue(try store.persons().isEmpty)
        XCTAssertThrowsError(try store.updatePerson(id: UUID(), draft: PersonDraft(displayName: "Missing")))
        _ = try store.createPerson(draft: PersonDraft(displayName: "After rollback"))
        XCTAssertEqual(try store.persons().count, 1)
    }
    func testPostgresWriteFailureRollsBackWholeImportAndSanitizesErrors() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("original", name: "Original")]))
        let before = try store.persons()
        try database.execute(
            "CREATE FUNCTION reject_write() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'private-test-marker'; END; $$")
        try database.execute("CREATE TRIGGER reject_write BEFORE UPDATE ON contact_records FOR EACH ROW EXECUTE FUNCTION reject_write()")
        XCTAssertThrowsError(
            try store.importDocument(document([imported("new", name: "New"), imported("original", name: "Changed")], time: 200))
        ) { error in
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("private-test-marker"))
            XCTAssertFalse(description.contains(self.database.connectionString))
            guard case StoreError.database(let diagnostic) = error else { return XCTFail("Expected sanitized database diagnostic") }
            XCTAssertTrue(diagnostic.contains("SQLSTATE P0001"))
            XCTAssertFalse(diagnostic.contains("private-test-marker"))
            XCTAssertFalse(diagnostic.contains(self.database.connectionString))
        }
        XCTAssertEqual(try store.persons(), before)
        try database.execute("DROP TRIGGER reject_write ON contact_records")
        XCTAssertEqual(try store.importDocument(document([imported("new", name: "New")], time: 200)).created, 1)
        XCTAssertEqual(try store.persons().count, 2)
    }
    func testCandidatesUseNormalizedIdentitiesNeverNames() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1", name: "Same"), imported("2", name: "Same")]))
        XCTAssertTrue(try store.duplicateCandidates().isEmpty)
        _ = try store.importDocument(
            document([
                imported("3", emails: ["A@EXAMPLE.ORG"], phones: ["+34 (600) 123-456"]),
                imported("4", emails: [" a@example.org "], phones: ["34600123456"]),
            ]))
        XCTAssertEqual(try store.duplicateCandidates().count, 1)
        XCTAssertEqual(try store.duplicateCandidates().first?.reasons.count, 2)
        XCTAssertEqual(try store.persons().count, 4)
    }
    func testMergeUnionsEveryValueAndReimportRoutesToSurvivor() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(
            document([
                imported("1", name: "First", emails: ["a@example.org"], phones: ["111"], tags: ["A"], notes: ["First note"]),
                imported("2", name: "Second", emails: ["b@example.org"], phones: ["222"], tags: ["B"], notes: ["Second note"]),
            ]))
        let all = try store.persons(), first = all.first { $0.displayName == "First" }!, second = all.first { $0.displayName == "Second" }!
        _ = try store.merge(survivorID: first.id, removedID: second.id)
        let merged = try XCTUnwrap(store.person(id: first.id))
        XCTAssertEqual(Set(merged.emails), ["a@example.org", "b@example.org"])
        XCTAssertEqual(Set(merged.phones), ["111", "222"])
        XCTAssertEqual(Set(merged.tags), ["A", "B"])
        XCTAssertEqual(merged.notes.count, 2)
        XCTAssertEqual(merged.identities.count, 2)
        XCTAssertEqual(merged.events.count, first.events.count + second.events.count + 1)
        XCTAssertTrue(merged.observations.contains { $0.field == "displayName" && $0.value == "Second" })
        _ = try store.importDocument(document([imported("2", name: "Second new", emails: ["c@example.org"])], time: 200))
        XCTAssertEqual(try store.persons().count, 1)
        XCTAssertTrue(try XCTUnwrap(store.person(id: first.id)).emails.contains("c@example.org"))
    }
    func testImportedScalarMergeChoiceSurvivesExactReimportAndUndo() throws {
        let store = try database.makeStore()
        let original = document([
            ImportedPerson(
                externalID: "1", displayName: "Chosen name", organization: "Chosen company", jobTitle: "Engineer",
                emails: ["one@example.org"]),
            ImportedPerson(
                externalID: "2", displayName: "Other name", organization: "Other company", jobTitle: "Designer", emails: ["two@example.org"]
            ),
        ])
        _ = try store.importDocument(original)
        let contacts = try store.persons()
        let a = try XCTUnwrap(contacts.first { $0.displayName == "Chosen name" }).id
        let b = try XCTUnwrap(contacts.first { $0.displayName == "Other name" }).id
        let mergeID = try store.merge(survivorID: a, removedID: b)
        let merged = try XCTUnwrap(store.person(id: a))
        XCTAssertTrue(merged.manualFields.isSuperset(of: ["displayName", "organization", "jobTitle"]))
        XCTAssertTrue(merged.observations.contains { $0.field == "organization" && $0.value == "Other company" })
        XCTAssertEqual(try store.importDocument(original), ImportResult(created: 0, updated: 0))
        XCTAssertEqual(try store.person(id: a), merged)
        try store.undoMerge(id: mergeID)
        XCTAssertEqual(try store.persons().count, 2)
        XCTAssertTrue(try XCTUnwrap(store.person(id: a)).manualFields.isEmpty)
        let secondMerge = try store.merge(survivorID: a, removedID: b)
        _ = try store.importDocument(
            document(
                [
                    ImportedPerson(
                        externalID: "2", displayName: "Updated remote", organization: "Updated company", jobTitle: "Lead",
                        emails: ["new@example.org"])
                ], time: 200))
        let updated = try XCTUnwrap(store.person(id: a))
        XCTAssertEqual(updated.displayName, "Chosen name")
        XCTAssertEqual(updated.organization, "Chosen company")
        XCTAssertEqual(updated.jobTitle, "Engineer")
        XCTAssertTrue(updated.emails.contains("new@example.org"))
        XCTAssertTrue(updated.observations.contains { $0.field == "displayName" && $0.value == "Updated remote" })
        XCTAssertEqual(try store.persons().count, 1)
        XCTAssertThrowsError(try store.undoMerge(id: secondMerge))
    }
    func testUndoRestoresSnapshotsAndRetainsAuditWithMonotonicRevisions() throws {
        let store = try database.makeStore()
        let first = try store.createPerson(draft: PersonDraft(displayName: "One", emails: ["one@example.org"]))
        let second = try store.createPerson(draft: PersonDraft(displayName: "Two", emails: ["two@example.org"]))
        let mergeID = try store.merge(survivorID: first, removedID: second)
        let revision = try XCTUnwrap(store.person(id: first)).revision
        try store.undoMerge(id: mergeID)
        XCTAssertEqual(try store.persons().count, 2)
        XCTAssertEqual(try store.person(id: first)?.emails, ["one@example.org"])
        XCTAssertGreaterThan(try XCTUnwrap(store.person(id: first)).revision, revision)
        XCTAssertGreaterThan(try XCTUnwrap(store.person(id: second)).revision, revision)
        XCTAssertNotNil(try store.mergeHistory().first?.undoneAt)
        XCTAssertThrowsError(try store.undoMerge(id: mergeID))
    }
    func testUndoRefusesLaterEditImportAndABA() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1"), imported("2")]))
        let all = try store.persons(), first = all[0].id, second = all[1].id
        let mergeID = try store.merge(survivorID: first, removedID: second)
        var draft = try XCTUnwrap(store.person(id: first)).draft
        let old = draft
        draft.displayName = "Temporary"
        try store.updatePerson(id: first, draft: draft)
        try store.updatePerson(id: first, draft: old)
        XCTAssertThrowsError(try store.undoMerge(id: mergeID))
        XCTAssertEqual(try store.persons().count, 1)
        _ = try store.importDocument(document([imported("3")]))
        let third = try XCTUnwrap(store.persons().first { $0.id != first }).id
        let next = try store.merge(survivorID: first, removedID: third)
        _ = try store.importDocument(document([imported("3", tags: ["Later"])], time: 200))
        XCTAssertThrowsError(try store.undoMerge(id: next))
    }
    func testManualScalarConflictSurvivesMergeAsSourceObservations() throws {
        let store = try database.makeStore()
        let a = try store.createPerson(draft: PersonDraft(displayName: "A", organization: "First company", jobTitle: "Engineer"))
        let b = try store.createPerson(draft: PersonDraft(displayName: "B", organization: "Second company", jobTitle: "Designer"))
        _ = try store.merge(survivorID: a, removedID: b)
        let merged = try XCTUnwrap(store.person(id: a))
        XCTAssertEqual(merged.organization, "First company")
        XCTAssertTrue(merged.identities.isEmpty)
        XCTAssertTrue(
            merged.observations.contains {
                $0.field == "organization" && $0.value == "Second company" && $0.source.identity.service == "manual"
                    && $0.source.identity.externalID == b.uuidString
            })
        XCTAssertTrue(merged.observations.contains { $0.field == "jobTitle" && $0.value == "Designer" })
        var draft = merged.draft
        draft.organization = ""
        draft.emails = ["manual@example.org"]
        try store.updatePerson(id: a, draft: draft)
        let changed = try XCTUnwrap(store.person(id: a))
        XCTAssertTrue(
            changed.observations.contains { $0.field == "organization" && $0.value.isEmpty && $0.source.identity.service == "manual" })
    }
    func testNewerIdenticalImportUpdatesTimestampWithoutGrowingHistoryAndBlocksUndo() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1", name: "One", notes: ["Note"]), imported("2", name: "Two")]))
        let all = try store.persons(), a = all.first { $0.displayName == "One" }!.id, b = all.first { $0.displayName == "Two" }!.id
        let mergeID = try store.merge(survivorID: a, removedID: b)
        let before = try XCTUnwrap(store.person(id: a))
        _ = try store.importDocument(document([imported("1", name: "One", notes: ["Note"])], time: 200))
        let after = try XCTUnwrap(store.person(id: a))
        XCTAssertEqual(after.notes.count, before.notes.count)
        XCTAssertEqual(after.observations.count, before.observations.count)
        XCTAssertEqual(after.events.count, before.events.count)
        XCTAssertGreaterThan(after.revision, before.revision)
        XCTAssertEqual(after.notes.first?.source.fetchedAt, Date(timeIntervalSince1970: 200))
        XCTAssertThrowsError(try store.undoMerge(id: mergeID))
    }
    func testChainedMergeUndoCannotReenableEarlierUndo() throws {
        let store = try database.makeStore()
        let a = try store.createPerson(draft: PersonDraft(displayName: "A"))
        let b = try store.createPerson(draft: PersonDraft(displayName: "B"))
        let c = try store.createPerson(draft: PersonDraft(displayName: "C"))
        let first = try store.merge(survivorID: a, removedID: b)
        let second = try store.merge(survivorID: a, removedID: c)
        XCTAssertThrowsError(try store.undoMerge(id: first))
        try store.undoMerge(id: second)
        XCTAssertThrowsError(try store.undoMerge(id: first))
        XCTAssertEqual(try store.persons().count, 2)
    }
}

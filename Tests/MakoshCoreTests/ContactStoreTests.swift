import Foundation
import XCTest
@testable import MakoshCore

final class ContactStoreTests: XCTestCase {
    private var database: PostgresTestDatabase!
    override func setUpWithError() throws { database = try PostgresTestDatabase() }
    override func tearDownWithError() throws { try database?.cleanup() }
    private func document(_ contacts: [ImportedContact], account: String = "a", time: TimeInterval = 100) -> ImportDocument {
        ImportDocument(source: ImportSource(service: "test", accountID: account), fetchedAt: Date(timeIntervalSince1970: time), contacts: contacts)
    }
    private func imported(_ id: String, name: String = "Name", emails: [String] = [], phones: [String] = [], tags: [String] = [], notes: [String] = []) -> ImportedContact {
        ImportedContact(externalID: id, displayName: name, phones: phones, emails: emails, tags: tags, notes: notes)
    }
    private final class ConcurrentStores: @unchecked Sendable {
        let stores: [ContactStore]
        let lock = NSLock()
        var errors: [Error] = []
        init(_ stores: [ContactStore]) { self.stores = stores }
        func write(_ index: Int) {
            do { _ = try stores[index % 2].createContact(draft: ContactDraft(displayName: "Contact \(index)")) }
            catch { lock.lock(); errors.append(error); lock.unlock() }
        }
    }
    func testConcurrentConnectionsDoNotLoseWrites() throws {
        let workers = ConcurrentStores([try database.makeStore(), try database.makeStore()])
        DispatchQueue.concurrentPerform(iterations: 20) { workers.write($0) }
        XCTAssertTrue(workers.errors.isEmpty)
        XCTAssertEqual(try workers.stores[0].contacts().count, 20)
    }
    func testInvalidSchemaNamesFailBeforeConnecting() throws {
        for schema in ["", "Upper", "bad-name", "a;DROP SCHEMA public", "é", String(repeating: "a", count: 64)] {
            XCTAssertThrowsError(try ContactStore(connectionString: database.connectionString, schema: schema)) { error in
                guard case StoreError.invalid = error else { return XCTFail("Expected schema validation error") }
            }
        }
    }
    func testConnectionErrorsDoNotRevealConnectionDetails() throws {
        let syntheticDSN = "host=127.0.0.1 port=1 dbname=private-test-marker user=test password=private-password"
        XCTAssertThrowsError(try ContactStore(connectionString: syntheticDSN, schema: database.schema)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-test-marker"))
            XCTAssertFalse(error.localizedDescription.contains("private-password"))
            XCTAssertFalse(error.localizedDescription.contains("127.0.0.1"))
        }
    }
    func testFutureSchemaFailsClosedWithoutWritingState() throws {
        let store = try database.makeStore()
        _ = try store.createContact(draft: ContactDraft(displayName: "Preserved"))
        let before = try database.execute("SELECT payload::text FROM state WHERE id=1")
        try database.execute("UPDATE state SET schema_version=2 WHERE id=1")
        XCTAssertThrowsError(try database.makeStore()) { error in
            guard case StoreError.unsupportedSchema(2) = error else { return XCTFail("Wrong error type") }
        }
        XCTAssertThrowsError(try store.contacts())
        XCTAssertThrowsError(try store.createContact(draft: ContactDraft(displayName: "Blocked")))
        XCTAssertEqual(try database.execute("SELECT payload::text FROM state WHERE id=1"), before)
        XCTAssertEqual(try database.execute("SELECT schema_version::text FROM state WHERE id=1"), [["2"]])
    }
    func testPersistenceAndIndependentStoresReloadBeforeWrites() throws {
        let first = try database.makeStore(), second = try database.makeStore()
        let id = try first.createContact(draft: ContactDraft(displayName: "One"))
        _ = try second.createContact(draft: ContactDraft(displayName: "Two"))
        try first.addNote(contactID: id, text: "Kept")
        let reopened = try database.makeStore()
        XCTAssertEqual(try reopened.contacts().count, 2)
        XCTAssertEqual(try reopened.contact(id: id)?.notes.first?.text, "Kept")
    }
    func testAccountIsolationAndIdempotentReimport() throws {
        let store = try database.makeStore()
        let doc = document([imported("1", emails: ["one@example.org"], notes: ["Note"])])
        XCTAssertEqual(try store.importDocument(doc), ImportResult(created: 1, updated: 0))
        let before = try store.contacts()
        XCTAssertEqual(try store.importDocument(doc), ImportResult(created: 0, updated: 0))
        XCTAssertEqual(try store.contacts(), before)
        _ = try store.importDocument(document([imported("1", name: "Other")], account: "b"))
        XCTAssertEqual(try store.contacts().count, 2)
    }
    func testUnicodeByteDistinctSourceIDsAndAccountsRemainSeparateAfterPersistence() throws {
        let store = try database.makeStore()
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        // Swift String's canonical equality is unsuitable for external source identifiers.
        _ = try store.importDocument(document([imported(composed, name: "Composed ID"), imported(decomposed, name: "Decomposed ID")]))
        _ = try store.importDocument(document([imported("same", name: "Composed account")], account: composed))
        _ = try store.importDocument(document([imported("same", name: "Decomposed account")], account: decomposed))
        let reopened = try database.makeStore()
        XCTAssertEqual(try reopened.contacts().count, 4)
        XCTAssertEqual(try reopened.importDocument(document([imported(composed, name: "Composed ID"), imported(decomposed, name: "Decomposed ID")])), ImportResult(created: 0, updated: 0))
        XCTAssertEqual(Set(try reopened.contacts().flatMap(\.identities).map(\.id)).count, 4)
    }
    func testManualOverridesAndRemovedArraysRemainSuppressedWithProvenance() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1", emails: ["old@example.org"], phones: ["123456"], tags: ["Imported"])]))
        var contact = try XCTUnwrap(store.contacts().first)
        var draft = contact.draft; draft.displayName = "Manual"; draft.emails = []; draft.phones = []; draft.tags = []
        try store.updateContact(id: contact.id, draft: draft)
        _ = try store.importDocument(document([imported("1", name: "Remote", emails: ["new@example.org"], phones: ["987654"], tags: ["New"])], time: 200))
        contact = try XCTUnwrap(store.contact(id: contact.id))
        XCTAssertEqual(contact.displayName, "Manual")
        XCTAssertTrue(contact.emails.isEmpty); XCTAssertTrue(contact.phones.isEmpty); XCTAssertTrue(contact.tags.isEmpty)
        XCTAssertTrue(contact.observations.contains { $0.field == "emails" && $0.value == "new@example.org" })
    }
    func testOldImportDoesNotOverwriteNewerStateOrGrowHistory() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1", name: "New")], time: 200))
        let before = try store.contacts()
        XCTAssertEqual(try store.importDocument(document([imported("1", name: "Old", notes: ["Old note"])], time: 100)), ImportResult(created: 0, updated: 0))
        XCTAssertEqual(try store.contacts(), before)
    }
    func testImportValidationIsAtomicAndNextTransactionWorks() throws {
        let store = try database.makeStore()
        XCTAssertThrowsError(try store.importDocument(document([imported("1"), imported("2", name: " ")])))
        XCTAssertTrue(try store.contacts().isEmpty)
        XCTAssertThrowsError(try store.importDocument(document([imported("1"), imported("1")])))
        XCTAssertTrue(try store.contacts().isEmpty)
        XCTAssertThrowsError(try store.updateContact(id: UUID(), draft: ContactDraft(displayName: "Missing")))
        _ = try store.createContact(draft: ContactDraft(displayName: "After rollback"))
        XCTAssertEqual(try store.contacts().count, 1)
    }
    func testPostgresWriteFailureRollsBackWholeImportAndSanitizesErrors() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("original", name: "Original")]))
        let before = try store.contacts()
        try database.execute("CREATE FUNCTION reject_write() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'private-test-marker'; END; $$")
        try database.execute("CREATE TRIGGER reject_write BEFORE UPDATE ON state FOR EACH ROW EXECUTE FUNCTION reject_write()")
        XCTAssertThrowsError(try store.importDocument(document([imported("new", name: "New"), imported("original", name: "Changed")], time: 200))) { error in
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("private-test-marker"))
            XCTAssertFalse(description.contains(self.database.connectionString))
            guard case StoreError.database(let diagnostic) = error else { return XCTFail("Expected sanitized database diagnostic") }
            XCTAssertTrue(diagnostic.contains("SQLSTATE P0001"))
            XCTAssertFalse(diagnostic.contains("private-test-marker"))
            XCTAssertFalse(diagnostic.contains(self.database.connectionString))
        }
        XCTAssertEqual(try store.contacts(), before)
        try database.execute("DROP TRIGGER reject_write ON state")
        XCTAssertEqual(try store.importDocument(document([imported("new", name: "New")], time: 200)).created, 1)
        XCTAssertEqual(try store.contacts().count, 2)
    }
    func testCandidatesUseNormalizedIdentitiesNeverNames() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1", name: "Same"), imported("2", name: "Same")]))
        XCTAssertTrue(try store.duplicateCandidates().isEmpty)
        _ = try store.importDocument(document([imported("3", emails: ["A@EXAMPLE.ORG"], phones: ["+34 (600) 123-456"]), imported("4", emails: [" a@example.org "], phones: ["34600123456"])]))
        XCTAssertEqual(try store.duplicateCandidates().count, 1)
        XCTAssertEqual(try store.duplicateCandidates().first?.reasons.count, 2)
        XCTAssertEqual(try store.contacts().count, 4)
    }
    func testMergeUnionsEveryValueAndReimportRoutesToSurvivor() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([
            imported("1", name: "First", emails: ["a@example.org"], phones: ["111"], tags: ["A"], notes: ["First note"]),
            imported("2", name: "Second", emails: ["b@example.org"], phones: ["222"], tags: ["B"], notes: ["Second note"])
        ]))
        let all = try store.contacts(), first = all.first { $0.displayName == "First" }!, second = all.first { $0.displayName == "Second" }!
        _ = try store.merge(survivorID: first.id, removedID: second.id)
        let merged = try XCTUnwrap(store.contact(id: first.id))
        XCTAssertEqual(Set(merged.emails), ["a@example.org", "b@example.org"])
        XCTAssertEqual(Set(merged.phones), ["111", "222"]); XCTAssertEqual(Set(merged.tags), ["A", "B"])
        XCTAssertEqual(merged.notes.count, 2); XCTAssertEqual(merged.identities.count, 2)
        XCTAssertEqual(merged.events.count, first.events.count + second.events.count + 1)
        XCTAssertTrue(merged.observations.contains { $0.field == "displayName" && $0.value == "Second" })
        _ = try store.importDocument(document([imported("2", name: "Second new", emails: ["c@example.org"])], time: 200))
        XCTAssertEqual(try store.contacts().count, 1)
        XCTAssertTrue(try XCTUnwrap(store.contact(id: first.id)).emails.contains("c@example.org"))
    }
    func testImportedScalarMergeChoiceSurvivesExactReimportAndUndo() throws {
        let store = try database.makeStore()
        let original = document([
            ImportedContact(externalID: "1", displayName: "Chosen name", organization: "Chosen company", jobTitle: "Engineer", emails: ["one@example.org"]),
            ImportedContact(externalID: "2", displayName: "Other name", organization: "Other company", jobTitle: "Designer", emails: ["two@example.org"])
        ])
        _ = try store.importDocument(original)
        let contacts = try store.contacts()
        let a = try XCTUnwrap(contacts.first { $0.displayName == "Chosen name" }).id
        let b = try XCTUnwrap(contacts.first { $0.displayName == "Other name" }).id
        let mergeID = try store.merge(survivorID: a, removedID: b)
        let merged = try XCTUnwrap(store.contact(id: a))
        XCTAssertTrue(merged.manualFields.isSuperset(of: ["displayName", "organization", "jobTitle"]))
        XCTAssertTrue(merged.observations.contains { $0.field == "organization" && $0.value == "Other company" })
        XCTAssertEqual(try store.importDocument(original), ImportResult(created: 0, updated: 0))
        XCTAssertEqual(try store.contact(id: a), merged)
        try store.undoMerge(id: mergeID)
        XCTAssertEqual(try store.contacts().count, 2)
        XCTAssertTrue(try XCTUnwrap(store.contact(id: a)).manualFields.isEmpty)
        let secondMerge = try store.merge(survivorID: a, removedID: b)
        _ = try store.importDocument(document([
            ImportedContact(externalID: "2", displayName: "Updated remote", organization: "Updated company", jobTitle: "Lead", emails: ["new@example.org"])
        ], time: 200))
        let updated = try XCTUnwrap(store.contact(id: a))
        XCTAssertEqual(updated.displayName, "Chosen name")
        XCTAssertEqual(updated.organization, "Chosen company")
        XCTAssertEqual(updated.jobTitle, "Engineer")
        XCTAssertTrue(updated.emails.contains("new@example.org"))
        XCTAssertTrue(updated.observations.contains { $0.field == "displayName" && $0.value == "Updated remote" })
        XCTAssertEqual(try store.contacts().count, 1)
        XCTAssertThrowsError(try store.undoMerge(id: secondMerge))
    }
    func testUndoRestoresSnapshotsAndRetainsAuditWithMonotonicRevisions() throws {
        let store = try database.makeStore()
        let first = try store.createContact(draft: ContactDraft(displayName: "One", emails: ["one@example.org"]))
        let second = try store.createContact(draft: ContactDraft(displayName: "Two", emails: ["two@example.org"]))
        let mergeID = try store.merge(survivorID: first, removedID: second)
        let revision = try XCTUnwrap(store.contact(id: first)).revision
        try store.undoMerge(id: mergeID)
        XCTAssertEqual(try store.contacts().count, 2)
        XCTAssertEqual(try store.contact(id: first)?.emails, ["one@example.org"])
        XCTAssertGreaterThan(try XCTUnwrap(store.contact(id: first)).revision, revision)
        XCTAssertGreaterThan(try XCTUnwrap(store.contact(id: second)).revision, revision)
        XCTAssertNotNil(try store.mergeHistory().first?.undoneAt)
        XCTAssertThrowsError(try store.undoMerge(id: mergeID))
    }
    func testUndoRefusesLaterEditImportAndABA() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1"), imported("2")]))
        let all = try store.contacts(), first = all[0].id, second = all[1].id
        let mergeID = try store.merge(survivorID: first, removedID: second)
        var draft = try XCTUnwrap(store.contact(id: first)).draft
        let old = draft; draft.displayName = "Temporary"
        try store.updateContact(id: first, draft: draft)
        try store.updateContact(id: first, draft: old)
        XCTAssertThrowsError(try store.undoMerge(id: mergeID))
        XCTAssertEqual(try store.contacts().count, 1)
        _ = try store.importDocument(document([imported("3")]))
        let third = try XCTUnwrap(store.contacts().first { $0.id != first }).id
        let next = try store.merge(survivorID: first, removedID: third)
        _ = try store.importDocument(document([imported("3", tags: ["Later"])], time: 200))
        XCTAssertThrowsError(try store.undoMerge(id: next))
    }
    func testManualScalarConflictSurvivesMergeAsSourceObservations() throws {
        let store = try database.makeStore()
        let a = try store.createContact(draft: ContactDraft(displayName: "A", organization: "First company", jobTitle: "Engineer"))
        let b = try store.createContact(draft: ContactDraft(displayName: "B", organization: "Second company", jobTitle: "Designer"))
        _ = try store.merge(survivorID: a, removedID: b)
        let merged = try XCTUnwrap(store.contact(id: a))
        XCTAssertEqual(merged.organization, "First company")
        XCTAssertTrue(merged.identities.isEmpty)
        XCTAssertTrue(merged.observations.contains { $0.field == "organization" && $0.value == "Second company" && $0.source.identity.service == "manual" && $0.source.identity.externalID == b.uuidString })
        XCTAssertTrue(merged.observations.contains { $0.field == "jobTitle" && $0.value == "Designer" })
        var draft = merged.draft; draft.organization = ""; draft.emails = ["manual@example.org"]
        try store.updateContact(id: a, draft: draft)
        let changed = try XCTUnwrap(store.contact(id: a))
        XCTAssertTrue(changed.observations.contains { $0.field == "organization" && $0.value.isEmpty && $0.source.identity.service == "manual" })
    }
    func testNewerIdenticalImportUpdatesTimestampWithoutGrowingHistoryAndBlocksUndo() throws {
        let store = try database.makeStore()
        _ = try store.importDocument(document([imported("1", name: "One", notes: ["Note"]), imported("2", name: "Two")]))
        let all = try store.contacts(), a = all.first { $0.displayName == "One" }!.id, b = all.first { $0.displayName == "Two" }!.id
        let mergeID = try store.merge(survivorID: a, removedID: b)
        let before = try XCTUnwrap(store.contact(id: a))
        _ = try store.importDocument(document([imported("1", name: "One", notes: ["Note"])], time: 200))
        let after = try XCTUnwrap(store.contact(id: a))
        XCTAssertEqual(after.notes.count, before.notes.count)
        XCTAssertEqual(after.observations.count, before.observations.count)
        XCTAssertEqual(after.events.count, before.events.count)
        XCTAssertGreaterThan(after.revision, before.revision)
        XCTAssertEqual(after.notes.first?.source.fetchedAt, Date(timeIntervalSince1970: 200))
        XCTAssertThrowsError(try store.undoMerge(id: mergeID))
    }
    func testChainedMergeUndoCannotReenableEarlierUndo() throws {
        let store = try database.makeStore()
        let a = try store.createContact(draft: ContactDraft(displayName: "A"))
        let b = try store.createContact(draft: ContactDraft(displayName: "B"))
        let c = try store.createContact(draft: ContactDraft(displayName: "C"))
        let first = try store.merge(survivorID: a, removedID: b)
        let second = try store.merge(survivorID: a, removedID: c)
        XCTAssertThrowsError(try store.undoMerge(id: first))
        try store.undoMerge(id: second)
        XCTAssertThrowsError(try store.undoMerge(id: first))
        XCTAssertEqual(try store.contacts().count, 2)
    }
}

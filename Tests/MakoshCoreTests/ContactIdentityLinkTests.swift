import XCTest
import Foundation
@testable import MakoshCore

final class ContactIdentityLinkTests: XCTestCase {
    private var database: PostgresTestDatabase!
    override func setUpWithError() throws { database = try PostgresTestDatabase() }
    override func tearDownWithError() throws { try database?.cleanup(); database = nil }
    private let source = ImportSource(service: "telegram",accountID: "synthetic")
    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func incoming(_ id: String = "42", name: String = "Imported") -> ImportedContact {
        ImportedContact(externalID: id,displayName: name,organization: "Source organization",phones: ["123"],notes: ["Source note"])
    }
    func testExplicitAttachPreservesManualFieldsAndProvenanceAndIsIdempotent() throws {
        let store = try database.makeStore()
        let target = try store.createContact(draft: ContactDraft(displayName: "Manual",phones: []))
        try store.addNote(contactID: target,text: "Manual note")
        XCTAssertEqual(try store.linkImportedContact(incoming(),source: source,fetchedAt: date(100),contactID: target),target)
        let linked = try XCTUnwrap(store.contact(id: target))
        XCTAssertEqual(linked.displayName,"Manual"); XCTAssertTrue(linked.phones.isEmpty)
        XCTAssertEqual(Set(linked.notes.map(\.text)),["Manual note","Source note"])
        XCTAssertTrue(linked.observations.contains { $0.field == "displayName" && $0.value == "Imported" && $0.source.identity.service == "telegram" })
        XCTAssertTrue(linked.observations.contains { $0.field == "phones" && $0.value == "123" })
        XCTAssertEqual(linked.events.filter { $0.kind == "identityLink" }.count,1)
        XCTAssertEqual(try store.linkImportedContact(incoming(),source: source,fetchedAt: date(100),contactID: nil),target)
        XCTAssertEqual(try store.contact(id: target),linked)
        XCTAssertEqual(try database.makeStore().contact(id: target),linked)
    }
    func testNewReuseAndOldSnapshotCannotOverwriteNewerSource() throws {
        let store = try database.makeStore()
        let id = try store.linkImportedContact(incoming(name: "First"),source: source,fetchedAt: date(100),contactID: nil)
        XCTAssertEqual(try store.linkImportedContact(incoming(name: "Newest"),source: source,fetchedAt: date(200),contactID: nil),id)
        let latest = try XCTUnwrap(store.contact(id: id))
        XCTAssertEqual(latest.displayName,"Newest")
        XCTAssertEqual(try store.linkImportedContact(incoming(name: "Old"),source: source,fetchedAt: date(50),contactID: id),id)
        XCTAssertEqual(try store.contact(id: id),latest)
        XCTAssertEqual(try store.contacts().count,1)
    }
    func testConflictMissingAndInvalidInputRollBackEntireState() throws {
        let store = try database.makeStore()
        _ = try store.linkImportedContact(incoming(),source: source,fetchedAt: date(100),contactID: nil)
        let target = try store.createContact(draft: ContactDraft(displayName: "Other"))
        let before = try database.execute("SELECT payload::text FROM state")
        for id in [target,UUID()] {
            XCTAssertThrowsError(try store.linkImportedContact(incoming(name: "Changed"),source: source,fetchedAt: date(200),contactID: id)) { error in
                guard case StoreError.invalid = error else { return XCTFail("Expected sanitized invalid error") }
            }
        }
        XCTAssertThrowsError(try store.linkImportedContact(incoming(""),source: source,fetchedAt: date(100),contactID: target))
        XCTAssertEqual(try database.execute("SELECT payload::text FROM state"),before)
    }
    func testAccountsServicesAndUnicodeBytesRemainDistinct() throws {
        let store = try database.makeStore()
        var ids = Set<UUID>()
        for scope in [source,ImportSource(service: "telegram",accountID: "other"),ImportSource(service: "other",accountID: "synthetic")] {
            ids.insert(try store.linkImportedContact(incoming(),source: scope,fetchedAt: date(100),contactID: nil))
        }
        for externalID in ["é","e\u{301}"] {
            ids.insert(try store.linkImportedContact(incoming(externalID),source: source,fetchedAt: date(100),contactID: nil))
        }
        for account in ["é","e\u{301}"] {
            ids.insert(try store.linkImportedContact(incoming(),source: ImportSource(service: "telegram",accountID: account),fetchedAt: date(100),contactID: nil))
        }
        XCTAssertEqual(ids.count,7); XCTAssertEqual(try store.contacts().count,7)
    }
    func testMergedIdentityRoutesToSurvivorAndLinkChangeBlocksUndo() throws {
        let store = try database.makeStore()
        let first = try store.linkImportedContact(incoming("1"),source: source,fetchedAt: date(100),contactID: nil)
        let second = try store.linkImportedContact(incoming("2"),source: source,fetchedAt: date(100),contactID: nil)
        let mergeID = try store.merge(survivorID: first,removedID: second)
        let before = try XCTUnwrap(store.contact(id: first))
        XCTAssertEqual(try store.linkImportedContact(incoming("2"),source: source,fetchedAt: date(100),contactID: nil),first)
        XCTAssertEqual(try store.contact(id: first),before)
        _ = try store.linkImportedContact(incoming("3"),source: source,fetchedAt: date(100),contactID: first)
        XCTAssertThrowsError(try store.undoMerge(id: mergeID))
        XCTAssertEqual(try store.importDocument(ImportDocument(source: source,fetchedAt: date(200),contacts: [incoming("2")] )).created,0)
        XCTAssertNil(try store.contact(id: second))
        XCTAssertEqual(try store.contacts().count,1)
    }
    func testNewerSourceStampOnExistingLinkBlocksMergeUndoWithoutFieldChange() throws {
        let store = try database.makeStore()
        let first = try store.linkImportedContact(incoming("1"),source: source,fetchedAt: date(100),contactID: nil)
        let second = try store.linkImportedContact(incoming("2"),source: source,fetchedAt: date(100),contactID: nil)
        let mergeID = try store.merge(survivorID: first,removedID: second)
        let before = try XCTUnwrap(store.contact(id: first))
        _ = try store.linkImportedContact(incoming("2"),source: source,fetchedAt: date(200),contactID: first)
        let after = try XCTUnwrap(store.contact(id: first))
        XCTAssertEqual(after.draft,before.draft)
        XCTAssertGreaterThan(after.revision,before.revision)
        XCTAssertThrowsError(try store.undoMerge(id: mergeID))
    }
    func testDuplicateOwnerCorruptionFailsClosed() throws {
        let store = try database.makeStore()
        _ = try store.linkImportedContact(incoming(),source: source,fetchedAt: date(100),contactID: nil)
        _ = try store.createContact(draft: ContactDraft(displayName: "Other"))
        try database.execute("UPDATE state SET payload=jsonb_set(payload,'{contacts,1,identities}',payload#>'{contacts,0,identities}')")
        let before = try database.execute("SELECT payload::text FROM state")
        XCTAssertThrowsError(try store.linkImportedContact(incoming(),source: source,fetchedAt: date(200),contactID: nil))
        XCTAssertEqual(try database.execute("SELECT payload::text FROM state"),before)
    }
    private final class ConcurrentLinks: @unchecked Sendable {
        let stores: [ContactStore]
        let lock = NSLock()
        var ids: [UUID] = []
        var errors = 0
        init(_ stores: [ContactStore]) { self.stores = stores }
        func link(_ index: Int) {
            do {
                let id = try stores[index % stores.count].linkImportedContact(ImportedContact(externalID: "42",displayName: "Synthetic"),source: ImportSource(service: "telegram",accountID: "synthetic"),fetchedAt: Date(timeIntervalSince1970: 100),contactID: nil)
                lock.lock(); ids.append(id); lock.unlock()
            } catch { lock.lock(); errors += 1; lock.unlock() }
        }
    }
    func testIndependentConnectionsAtomicallyReuseOneOwner() throws {
        let links = ConcurrentLinks([try database.makeStore(),try database.makeStore()])
        DispatchQueue.concurrentPerform(iterations: 12) { links.link($0) }
        XCTAssertEqual(links.errors,0); XCTAssertEqual(Set(links.ids).count,1)
        XCTAssertEqual(try links.stores[0].contacts().count,1)
        XCTAssertEqual(try links.stores[0].contacts().first?.events.filter { $0.kind == "identityLink" }.count,1)
    }
}

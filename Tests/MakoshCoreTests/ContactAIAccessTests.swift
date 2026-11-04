import Foundation
import XCTest
@testable import MakoshCore

final class ContactAIAccessTests: XCTestCase {
    private var database: PostgresTestDatabase!
    override func setUpWithError() throws { database = try PostgresTestDatabase() }
    override func tearDownWithError() throws { try database?.cleanup() }
    private func store() throws -> ContactStore { try ContactStore(connectionString: database.connectionString, schema: database.schema) }

    func testDefaultInheritForOldRows() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","displayName":"Old","organization":"","jobTitle":"","phones":[],"emails":[],"tags":[],"identities":[],"observations":[],"notes":[],"events":[],"manualFields":[],"revision":3}"#
        let contact = try JSONDecoder().decode(Contact.self, from: Data(json.utf8))
        XCTAssertEqual(contact.aiAccess, .inherit)
        XCTAssertEqual(Contact(displayName: "New").aiAccess, .inherit)
    }

    func testSetBumpsRevisionAndBlocksStaleUndo() throws {
        let store = try store()
        let survivor = try store.createContact(draft: ContactDraft(displayName: "A"))
        let removed = try store.createContact(draft: ContactDraft(displayName: "B"))
        let merge = try store.merge(survivorID: survivor, removedID: removed)
        let before = try XCTUnwrap(store.contact(id: survivor)).revision
        try store.setAIAccess(contactID: survivor, access: .forbidden)
        let after = try XCTUnwrap(store.contact(id: survivor))
        XCTAssertEqual(after.aiAccess, .forbidden)
        XCTAssertEqual(after.revision, before + 1)
        XCTAssertEqual(after.events.last?.kind, "aiAccess")
        XCTAssertThrowsError(try store.undoMerge(id: merge))
    }

    func testMergeKeepsForbidden() throws {
        let store = try store()
        let allowed = try store.createContact(draft: ContactDraft(displayName: "Allowed"))
        let forbidden = try store.createContact(draft: ContactDraft(displayName: "Forbidden"))
        try store.setAIAccess(contactID: allowed, access: .allowed)
        try store.setAIAccess(contactID: forbidden, access: .forbidden)
        _ = try store.merge(survivorID: allowed, removedID: forbidden)
        XCTAssertEqual(try XCTUnwrap(store.contact(id: allowed)).aiAccess, .forbidden)
    }

    func testMergeAllowedOverInherit() throws {
        let store = try store()
        let inherit = try store.createContact(draft: ContactDraft(displayName: "Inherit"))
        let allowed = try store.createContact(draft: ContactDraft(displayName: "Allowed"))
        try store.setAIAccess(contactID: allowed, access: .allowed)
        _ = try store.merge(survivorID: inherit, removedID: allowed)
        XCTAssertEqual(try XCTUnwrap(store.contact(id: inherit)).aiAccess, .allowed)
    }

    func testUndoRestoresBothPolicies() throws {
        let store = try store()
        let allowed = try store.createContact(draft: ContactDraft(displayName: "Allowed"))
        let forbidden = try store.createContact(draft: ContactDraft(displayName: "Forbidden"))
        try store.setAIAccess(contactID: allowed, access: .allowed)
        try store.setAIAccess(contactID: forbidden, access: .forbidden)
        let merge = try store.merge(survivorID: allowed, removedID: forbidden)
        try store.undoMerge(id: merge)
        XCTAssertEqual(try XCTUnwrap(store.contact(id: allowed)).aiAccess, .allowed)
        XCTAssertEqual(try XCTUnwrap(store.contact(id: forbidden)).aiAccess, .forbidden)
    }

    func testWorkerCommandSetsAccess() async throws {
        let worker = ContactWorkspaceWorker(configuration: .init(connectionString: database.connectionString, schema: database.schema))
        _ = try await worker.open()
        let saved = try await worker.apply(.save(draft: ContactDraft(displayName: "Worker"), id: nil))
        guard case .saved(let id) = saved.value else { return XCTFail("not saved") }
        let result = try await worker.apply(.setAIAccess(contactID: id, access: .forbidden))
        XCTAssertEqual(result.value, .aiAccessSet)
        XCTAssertEqual(result.snapshot?.contacts.first { $0.id == id }?.aiAccess, .forbidden)
    }
}

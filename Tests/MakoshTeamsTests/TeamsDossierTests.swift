import XCTest
import MakoshCore
@testable import MakoshTeams

final class TeamsDossierTests: XCTestCase {
    func testDossierRetainsTenantProvenanceAndManualOverrides() throws {
        let db = try TeamsTestDatabase(); defer { try? db.cleanup() }
        let store = try ContactStore(connectionString: db.configuration.connectionString, schema: db.configuration.schema)
        let person = TeamsPerson(userID: "88888888-8888-4888-8888-888888888888", tenantID: "55555555-5555-4555-8555-555555555555", displayName: "Guest", email: "guest@example.invalid")
        let contact = try XCTUnwrap(person.dossierContact)
        let source = ImportSource(service: "teams", accountID: teamsTestScope.accountID.uuidString)
        let id = try store.linkImportedContact(contact, source: source, fetchedAt: Date(), contactID: nil)
        var draft = try XCTUnwrap(store.contact(id: id)).draft; draft.displayName = "Manual name"
        try store.updateContact(id: id, draft: draft)
        _ = try store.linkImportedContact(contact, source: source, fetchedAt: Date().addingTimeInterval(1), contactID: id)
        let result = try XCTUnwrap(store.contact(id: id))
        XCTAssertEqual(result.displayName, "Manual name")
        XCTAssertEqual(result.identities.first?.service, "teams")
        XCTAssertEqual(result.identities.first?.externalID, contact.externalID)
        XCTAssertNotEqual(person.dossierContact?.externalID, TeamsPerson(userID: person.userID, tenantID: teamsTestScope.tenantID, displayName: "Other tenant", email: nil).dossierContact?.externalID)
        XCTAssertNil(TeamsPerson(userID: person.userID, tenantID: "", displayName: "Unknown tenant", email: nil).dossierContact)
    }
}

import XCTest
import MakoshCore
@testable import MakoshTeams

@MainActor
final class TeamsAIAuthorTests: XCTestCase {
    func testIndexedAuthorMatchesDossierIdentity() async throws {
        let db = try TeamsTestDatabase()
        addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let guest = TeamsPerson(
            userID: "88888888-8888-4888-8888-888888888888", tenantID: "55555555-5555-4555-8555-555555555555",
            displayName: "Guest", email: nil)
        let message = TeamsMessage(
            id: "g1", scope: teamsTestScope, body: "from a guest", contentType: "text", author: guest,
            createdAt: Date(timeIntervalSince1970: 10), modifiedAt: nil, deletedAt: nil, attachments: [], replyTo: nil)
        _ = try await repository.commit(
            page: TeamsPage(values: [message], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        try await TeamsArchiveProjection(configuration: db.configuration, repository: repository, keyProvider: teamsTestKey).drain()
        await repository.close()
        let source = try MessageArchiveIndexSource(
            connectionString: db.configuration.connectionString, schema: db.configuration.schema,
            keyProvider: teamsTestKey, authorKeys: ["teams": TeamsPerson.archiveAuthorKey])
        let items = try await source.items(after: 0, limit: 200)
        XCTAssertEqual(items.map(\.text), ["from a guest"])
        let expected = try XCTUnwrap(guest.dossierPerson).externalID
        XCTAssertEqual(
            items.first?.author, ServiceIdentity(service: "teams", accountID: teamsTestScope.accountID.uuidString, externalID: expected))
    }

    func testUnverifiedPayloadGivesNoAuthor() throws {
        XCTAssertNil(TeamsPerson.archiveAuthorKey(Data("{}".utf8)))
        XCTAssertNil(TeamsPerson.archiveAuthorKey(Data("not json".utf8)))
        let partial = try JSONEncoder().encode([
            "author": ["userID": "88888888-8888-4888-8888-888888888888", "tenantID": "", "displayName": "X"]
        ])
        XCTAssertNil(TeamsPerson.archiveAuthorKey(partial))
    }
}

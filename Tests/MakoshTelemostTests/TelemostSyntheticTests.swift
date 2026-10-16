import XCTest
@testable import MakoshCore
@testable import MakoshTelemost

@MainActor final class TelemostSyntheticTests: XCTestCase {
    func testSyntheticFactoryHasTwoAccountsPagingUnknownAndRestartRetention() async throws {
        let db = try TelemostTestDatabase(); addTeardownBlock { try db.cleanup() }
        let original = db.configuration.connectionString
        let connection: String
        if var parts = URLComponents(string: original), ["postgres", "postgresql"].contains(parts.scheme ?? "") {
            parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "hostaddr" } + [.init(name: "hostaddr", value: "127.0.0.1")]; connection = parts.string!
        } else { connection = original + " hostaddr=127.0.0.1" }
        let config = ContactWorkspaceConfiguration(connectionString: connection, schema: db.configuration.schema, archiveSchema: db.configuration.archiveSchema)
        let args = ["QA", "--telemost-synthetic-preview", "--database-config", "/owned/db.json", "--telemost-qa-exports", "/owned/exports"]
        let contacts = ContactWorkspaceWorker(configuration: config)
        let worker = try await TelemostWorker.synthetic(configuration: config, arguments: args, contacts: contacts)
        let value = try await worker.snapshot(); XCTAssertEqual(value.accounts.count, 2)
        XCTAssertEqual(value.connections.values.filter { $0 == .synthetic }.count, 2)
        let account = value.accounts.first { $0.name.contains("Проектная") }!
        let first = try await worker.page(accountID: account.id, query: "Планирование", before: nil, limit: 50)
        let second = try await worker.page(accountID: account.id, query: "Планирование", before: first.next, limit: 50)
        XCTAssertEqual(first.values.count, 50); XCTAssertEqual(second.values.count, 15)
        let unknown = try XCTUnwrap(value.operations.first { $0.state == .unknown })
        do { _ = try await worker.create(accountID: account.id, request: .init(waitingRoom: .admins)); XCTFail("unknown must block") } catch { XCTAssertEqual(error as? TelemostFailure, .unknown) }
        try await worker.resolve(operationID: unknown.id, resolution: .dismissUnknownAndAllowNewAttempt)
        let operation = try await worker.create(accountID: account.id, request: .init(waitingRoom: .organization))
        let after = try await worker.snapshot(); XCTAssertEqual(after.operations.first { $0.id == operation }?.state, .accepted)
        await worker.close()
        let reopened = try await TelemostWorker.synthetic(configuration: config, arguments: args, contacts: contacts)
        let restored = try await reopened.snapshot(); XCTAssertEqual(restored.operations.count, 3)
        XCTAssertEqual(restored.operations.first { $0.id == unknown.id }?.state, .resolved)
        await reopened.close()
    }
}

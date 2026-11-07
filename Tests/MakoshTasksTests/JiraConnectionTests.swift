import Foundation
import MakoshCore
import XCTest
@testable import MakoshTasks

final class JiraConnectionTests: XCTestCase {
    private func connection(_ url: String = "https://jira.test", email: String = "me@example.com") -> JiraConnection {
        JiraConnection(name: "Работа", origin: URL(string: url)!, email: email)
    }

    func testValidationRejectsHttpAndPath() {
        XCTAssertNoThrow(try connection().validated())
        XCTAssertNoThrow(try connection("https://jira.test/").validated(), "a trailing slash is fine")
        XCTAssertThrowsError(try connection("http://jira.test").validated())
        XCTAssertThrowsError(try connection("https://jira.test/jira").validated())
        XCTAssertThrowsError(try connection("https://jira.test?x=1").validated())
        XCTAssertThrowsError(try connection(email: "nobody").validated())
        XCTAssertThrowsError(try connection(email: "a@b@c").validated())
        XCTAssertThrowsError(try JiraConnection(name: "", origin: URL(string: "https://jira.test")!, email: "me@example.com").validated())
    }

    func testTokenWithNewlineIsRejected() async throws {
        let vault = JiraTokenVault(access: .memory())
        let id = UUID()
        do {
            try await vault.save("abc\ndef", connectionID: id)
            XCTFail("a newline inside the token must be refused")
        } catch let error as TasksFailure { XCTAssertEqual(error, .invalidToken) }
        try await vault.save("  token-123 \n", connectionID: id)
        let loaded = try await vault.load(connectionID: id)
        XCTAssertEqual(loaded, "token-123", "surrounding whitespace is trimmed")
        try await vault.save("", connectionID: id)
        let removed = try await vault.load(connectionID: id)
        XCTAssertNil(removed)
    }

    func testRemoveDeletesTokenBeforeConnection() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var events: [String] = []
            func add(_ event: String) { lock.withLock { events.append(event) } }
        }
        let log = Log()
        let memory = JiraKeychainAccess.memory()
        let access = JiraKeychainAccess(
            read: memory.read,
            write: { id, data in memory.write(id, data) },
            remove: { id in
                log.add("token")
                return memory.remove(id)
            })
        let vault = JiraTokenVault(access: access)
        let registry = JiraConnectionRegistry(store: store, vault: vault)
        let connection = connection()
        try await registry.save(connection, token: "t")
        let stored = try await registry.connections()
        XCTAssertEqual(stored.map(\.id), [connection.id])
        // A store that refuses the delete must not leave the token behind.
        await store.close()
        do {
            try await registry.remove(connection.id)
            XCTFail("a closed store cannot remove the connection")
        } catch {}
        XCTAssertEqual(log.events, ["token"], "the token went first")
        let token = try await vault.load(connectionID: connection.id)
        XCTAssertNil(token)
    }

    func testRemoveKeepsTasksWithMembershipNone() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let registry = JiraConnectionRegistry(store: store, vault: JiraTokenVault(access: .memory()))
        let connection = connection()
        try await registry.save(connection, token: "t")
        let identity = ServiceIdentity(service: "jira", accountID: connection.id.uuidString, externalID: "10001")
        let task = try await store.insert(Task(title: "QA-1", source: TaskSource(identity: identity, membership: .assigned)), actor: .provider)
        try await registry.remove(connection.id)
        let remaining = try await registry.connections()
        XCTAssertTrue(remaining.isEmpty)
        let after = try await store.task(id: task.id)
        XCTAssertEqual(after?.source?.membership, TaskMembership.none)
        XCTAssertEqual(after?.source?.identity, identity, "the identity and history stay")
    }

    func testConnectionsRoundTrip() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let registry = JiraConnectionRegistry(store: store, vault: JiraTokenVault(access: .memory()))
        var connection = connection()
        connection.pollInterval = 120
        connection.mentions = false
        connection.suggestWorklog = false
        connection.accountID = "me-1"
        try await registry.save(connection, token: "secret")
        let loaded = try await registry.connections()
        XCTAssertEqual(loaded, [connection])
        let token = try await registry.token(connectionID: connection.id)
        XCTAssertEqual(token, "secret")
        connection.name = "Переименовано"
        try await registry.save(connection, token: nil)
        let renamed = try await registry.connections()
        XCTAssertEqual(renamed.first?.name, "Переименовано")
        let kept = try await registry.token(connectionID: connection.id)
        XCTAssertEqual(kept, "secret", "saving without a token keeps the old one")
    }
}

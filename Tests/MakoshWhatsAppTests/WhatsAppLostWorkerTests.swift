import Foundation
import MakoshCore
import XCTest
@testable import MakoshWhatsApp

/// A session whose worker process is gone: every call reports `closed`.
private actor LostTransport: WhatsAppTransport {
    let lost: Bool
    init(lost: Bool) { self.lost = lost }
    var lostReason: String? { lost ? "exit 101" : nil }
    func connect() {}
    func disconnect() {}
    func close() {}
    func status() throws -> WhatsAppConnectionStatus {
        if lost { throw WhatsAppFailure.closed }
        var status = WhatsAppConnectionStatus()
        status.state = "connected"
        return status
    }
    func chats(before: WhatsAppCursor?) -> [WhatsAppChat] { [] }
    func journal() throws -> [WhatsAppJournalEntry] {
        if lost { throw WhatsAppFailure.closed }
        return []
    }
    func acknowledge(_ sequence: Int64) {}
    func callMedia(_ request: WhatsAppCallExchange) throws -> WhatsAppCallOutput { throw WhatsAppFailure.closed }
    func perform(chat: String, action: WhatsAppAction) throws -> WhatsAppMutationResult { throw WhatsAppFailure.closed }
}

private actor Sessions {
    private(set) var created = 0
    func next() -> LostTransport {
        created += 1
        return LostTransport(lost: created == 1)
    }
}

final class WhatsAppLostWorkerTests: XCTestCase {
    func testLostWorkerShowsHowItEndedAndReconnectsOnce() async throws {
        guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
            throw XCTSkip("PostgreSQL required")
        }
        let schema = "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
        let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x76, count: 32) }
        let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
        let account = WhatsAppAccount(name: "Lost worker")
        try await repository.saveAccount(account)
        let sessions = Sessions()
        let worker = WhatsAppWorker(factory: { _ in await sessions.next() }, keyProvider: keys)
        _ = try await worker.load(configuration: config)
        try await worker.connect(accountID: account.id)
        let afterConnect = await sessions.created
        XCTAssertEqual(afterConnect, 1)

        let first = try await worker.snapshot(accountID: account.id)
        XCTAssertEqual(first.status.state, "failed")
        XCTAssertEqual(first.status.error, "closed: exit 101")

        // The lost session is replaced without the user pressing Connect.
        for _ in 0..<200 where await sessions.created < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let created = await sessions.created
        XCTAssertEqual(created, 2)
        let recovered = try await worker.snapshot(accountID: account.id)
        XCTAssertEqual(recovered.status.state, "connected")
        await worker.shutdown()
    }

    func testDisconnectBeforeRecoveryKeepsTheAccountOffline() async throws {
        guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
            throw XCTSkip("PostgreSQL required")
        }
        let schema = "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
        let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x76, count: 32) }
        let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
        let account = WhatsAppAccount(name: "Lost then disconnected")
        try await repository.saveAccount(account)
        let sessions = Sessions()
        let worker = WhatsAppWorker(factory: { _ in await sessions.next() }, keyProvider: keys)
        _ = try await worker.load(configuration: config)
        try await worker.connect(accountID: account.id)
        _ = try await worker.snapshot(accountID: account.id)
        try await worker.disconnect(accountID: account.id)
        try await Task.sleep(for: .milliseconds(300))
        let created = await sessions.created
        XCTAssertLessThanOrEqual(created, 2)
        let status = try await worker.snapshot(accountID: account.id).status
        XCTAssertNotEqual(status.state, "connected", "an explicit disconnect wins over recovery")
        await worker.shutdown()
    }
}

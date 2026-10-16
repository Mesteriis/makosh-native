import XCTest
import Security
@testable import MakoshTelegram

@MainActor final class TelegramProxyVaultTests: XCTestCase {
    private func configuration() throws -> TelegramProxyConfiguration {
        var d = TelegramProxyDraft(); d.host = "proxy.example.invalid"; d.port = "1080"
        d.username = "SyntheticUser"; d.password = "SyntheticPassword"
        let server = try TelegramProxyServer(draft: d)
        var c = TelegramProxyConfiguration(); c.servers = [server]; c.selected = server.id; c.enabled = true; return c
    }
    func testRoundTripUsesKeychainPayloadAndStaleRevisionCannotOverwriteLaterEdit() async throws {
        let store = TelegramProxyTestStore(), vault = store.vault()
        let empty = try await vault.read(); XCTAssertFalse(empty.configuration.enabled); XCTAssertNil(empty.token)
        let first = try await vault.save(configuration(), expected: empty)
        let readFirst = try await vault.read()
        XCTAssertEqual(first.token?.count, 16); XCTAssertEqual(readFirst, first)
        var disabled = first.configuration; disabled.enabled = false
        let second = try await store.vault().save(disabled, expected: first)
        await telegramProxyAssertThrows { try await vault.save(first.configuration, expected: first) }
        let readSecond = try await vault.read()
        XCTAssertEqual(readSecond, second); XCTAssertEqual(store.writes, 2)
        XCTAssertEqual(store.item?[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(store.item?[kSecUseDataProtectionKeychain as String])
    }
    func testLockedCorruptOversizedOrWrongSchemaDoesNotFallBackToDirectConnection() async throws {
        let store = TelegramProxyTestStore(), vault = store.vault(); store.unavailable = true
        await telegramProxyAssertThrows { try await vault.read() }; XCTAssertEqual(store.writes, 0)
        store.unavailable = false
        for data in [Data("broken".utf8), Data(repeating: 1, count: 65_537), Data("{\"version\":999}".utf8)] {
            store.item = [kSecValueData as String:data, kSecAttrGeneric as String:Data(repeating: 1, count: 16)]
            await telegramProxyAssertThrows { try await vault.read() }; XCTAssertEqual(store.writes, 0)
        }
    }
    func testFailedUpdatePreservesPreviousSettingsWithoutPlaintextFallbackOrCreate() async throws {
        let store = TelegramProxyTestStore(), vault = store.vault()
        let empty = try await vault.read(), first = try await vault.save(configuration(), expected: empty)
        store.failedUpdate = true
        var next = first.configuration; next.enabled = false
        await telegramProxyAssertThrows { try await vault.save(next, expected: first) }
        let fresh = try await vault.read()
        XCTAssertEqual(fresh, first); XCTAssertEqual(store.writes, 1)
    }
    func testConcurrentInitialCreationCannotReplaceWinningRecord() async throws {
        let store = TelegramProxyTestStore(), vault = store.vault()
        let empty = try await vault.read(), winner = try await store.vault().save(configuration(), expected: empty)
        await telegramProxyAssertThrows { try await vault.save(.init(), expected: empty) }
        let fresh = try await vault.read()
        XCTAssertEqual(fresh, winner); XCTAssertEqual(store.writes, 1)
    }
    func testConcurrentUpdatesFromSameRevisionHaveExactlyOneWinner() async throws {
        let store = TelegramProxyTestStore(), vault = store.vault()
        let first = try await vault.save(configuration(), expected: .init(configuration: .init(), token: nil))
        var disabled = first.configuration; disabled.enabled = false
        let next = disabled
        let a = Task { try await vault.save(next, expected: first) }
        let b = Task { try await vault.save(next, expected: first) }
        let outcomes = await [a.result, b.result]
        XCTAssertEqual(outcomes.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(store.writes, 2)
        let fresh = try await vault.read(); XCTAssertFalse(fresh.configuration.enabled)
    }
}

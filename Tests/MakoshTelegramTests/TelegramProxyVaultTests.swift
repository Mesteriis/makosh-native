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
    func testRoundTripUsesKeychainPayloadAndStaleRevisionCannotOverwriteLaterEdit() throws {
        let store = TelegramProxyTestStore(), vault = store.vault()
        let empty = try vault.read(); XCTAssertFalse(empty.configuration.enabled); XCTAssertNil(empty.token)
        let first = try vault.save(configuration(), expected: empty)
        XCTAssertEqual(first.token?.count, 16); XCTAssertEqual(try vault.read(), first)
        var disabled = first.configuration; disabled.enabled = false
        let second = try store.vault().save(disabled, expected: first)
        XCTAssertThrowsError(try vault.save(first.configuration, expected: first))
        XCTAssertEqual(try vault.read(), second); XCTAssertEqual(store.writes, 2)
        XCTAssertEqual(store.item?[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(store.item?[kSecUseDataProtectionKeychain as String])
    }
    func testLockedCorruptOversizedOrWrongSchemaDoesNotFallBackToDirectConnection() throws {
        let store = TelegramProxyTestStore(), vault = store.vault(); store.unavailable = true
        XCTAssertThrowsError(try vault.read()); XCTAssertEqual(store.writes, 0)
        store.unavailable = false
        for data in [Data("broken".utf8), Data(repeating: 1, count: 65_537), Data("{\"version\":999}".utf8)] {
            store.item = [kSecValueData as String:data, kSecAttrGeneric as String:Data(repeating: 1, count: 16)]
            XCTAssertThrowsError(try vault.read()); XCTAssertEqual(store.writes, 0)
        }
    }
    func testFailedUpdatePreservesPreviousSettingsWithoutPlaintextFallbackOrCreate() throws {
        let store = TelegramProxyTestStore(), vault = store.vault()
        let first = try vault.save(configuration(), expected: vault.read())
        store.failedUpdate = true
        var next = first.configuration; next.enabled = false
        XCTAssertThrowsError(try vault.save(next, expected: first))
        XCTAssertEqual(try vault.read(), first); XCTAssertEqual(store.writes, 1)
    }
    func testConcurrentInitialCreationCannotReplaceWinningRecord() throws {
        let store = TelegramProxyTestStore(), vault = store.vault()
        let empty = try vault.read(), winner = try store.vault().save(configuration(), expected: empty)
        XCTAssertThrowsError(try vault.save(.init(), expected: empty))
        XCTAssertEqual(try vault.read(), winner); XCTAssertEqual(store.writes, 1)
    }
}

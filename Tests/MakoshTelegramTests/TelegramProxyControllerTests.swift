import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramProxyControllerTests: XCTestCase {
    private final class Request: TelegramProxyRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Target: TelegramProxyTarget {
        var isAvailable = true, stopped = false
        var values: [TelegramProxyConfiguration] = []
        var callbacks: [@MainActor (Bool) -> Void] = []
        func apply(_ configuration: TelegramProxyConfiguration, receive: @escaping @MainActor (Bool) -> Void) -> any TelegramProxyRequest {
            values.append(configuration); callbacks.append(receive); return Request()
        }
        func failClosed() { stopped = true; isAvailable = false }
    }
    private func draft(_ host: String = "proxy.example.invalid") -> TelegramProxyDraft {
        var d = TelegramProxyDraft(); d.host = host; d.port = "1080"; d.password = "SyntheticPassword"; d.username = "SyntheticUser"; return d
    }
    func testExplicitConfirmationWritesThenAppliesEveryOwnedConnectionAndWaitsForAcknowledgements() throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault())
        XCTAssertNil(c.enabled); XCTAssertEqual(store.writes, 0)
        c.open(); let first = Target(), second = Target()
        let a = UUID(), b = UUID()
        _ = try c.settingsForConnection(clientID: a); c.register(first, clientID: a)
        _ = try c.settingsForConnection(clientID: b); c.register(second, clientID: b)
        let confirmation = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        XCTAssertEqual(store.writes, 0); XCTAssertTrue(first.values.isEmpty)
        c.confirm(confirmation)
        XCTAssertEqual(store.writes, 1); XCTAssertEqual(c.phase, .applying)
        XCTAssertEqual(first.values.count, 1); XCTAssertEqual(second.values.count, 1)
        first.callbacks[0](true); XCTAssertEqual(c.phase, .applying)
        second.callbacks[0](true); XCTAssertEqual(c.phase, .idle); XCTAssertEqual(c.enabled, true)
        c.confirm(confirmation); XCTAssertEqual(store.writes, 1)
    }
    func testStaleEditorAndOpeningConnectionCannotChangeSettings() throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); c.open()
        let stale = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        c.close(); c.open(); c.confirm(stale); XCTAssertEqual(store.writes, 0)
        let id = UUID(); _ = try c.settingsForConnection(clientID: id)
        XCTAssertTrue(c.isOpening); XCTAssertNil(c.prepare(.add(draft()), contextID: c.contextID))
        c.unregister(clientID: id); XCTAssertFalse(c.isOpening)
        XCTAssertNotNil(c.prepare(.add(draft()), contextID: c.contextID))
    }
    func testUnknownWriteStopsConnectionsAndExplicitRetryDoesNotRewritePersistedRecord() throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); c.open()
        let target = Target(), id = UUID(); _ = try c.settingsForConnection(clientID: id); c.register(target, clientID: id)
        let choice = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        store.unavailable = true; c.confirm(choice)
        XCTAssertEqual(store.writes, 1); XCTAssertEqual(c.phase, .uncertain); XCTAssertTrue(target.stopped); XCTAssertTrue(target.values.isEmpty)
        store.unavailable = false; c.open()
        let retry = try XCTUnwrap(c.prepareRetry(contextID: c.contextID)); c.confirm(retry)
        XCTAssertEqual(store.writes, 1); XCTAssertEqual(c.enabled, true); XCTAssertEqual(c.phase, .idle)
    }
    func testFalseOrLateAcknowledgementNeverClaimsAppliedAndCloseDoesNotCancelConfirmedOperation() throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); c.open()
        let target = Target(), id = UUID(); _ = try c.settingsForConnection(clientID: id); c.register(target, clientID: id)
        c.confirm(try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID)))
        c.close(); XCTAssertEqual(c.phase, .applying)
        target.callbacks[0](false); XCTAssertEqual(c.phase, .uncertain); XCTAssertTrue(target.stopped)
        target.callbacks[0](true); XCTAssertEqual(c.phase, .uncertain)
    }
    func testRemovingActiveServerDisablesInsteadOfSelectingAnother() throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); c.open()
        c.confirm(try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID)))
        c.confirm(try XCTUnwrap(c.prepare(.add(draft("another.example.invalid")), contextID: c.contextID)))
        let selected = try XCTUnwrap(c.selected)
        c.confirm(try XCTUnwrap(c.prepare(.remove(selected), contextID: c.contextID)))
        XCTAssertEqual(c.servers.count, 1); XCTAssertNil(c.selected); XCTAssertEqual(c.enabled, false)
        XCTAssertNil(c.prepare(.enabled(true), contextID: c.contextID))
    }
    func testNetworkReplacementDuringApplyRejectsAcknowledgementFromOldNetwork() throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); c.open()
        let old = Target(), replacement = Target(), id = UUID()
        _ = try c.settingsForConnection(clientID: id); c.register(old, clientID: id)
        c.confirm(try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID)))
        c.register(replacement, clientID: id)
        old.callbacks[0](true); XCTAssertEqual(c.phase, .applying)
        replacement.callbacks[0](true); XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(replacement.values[0], try store.vault().read().configuration)
    }
    func testStoppedOpeningCannotRegisterLateNetworkAfterProxyChange() throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); c.open()
        let id = UUID(), late = Target()
        _ = try c.settingsForConnection(clientID: id); c.unregister(clientID: id)
        c.confirm(try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID)))
        c.register(late, clientID: id)
        XCTAssertTrue(late.stopped); XCTAssertTrue(late.values.isEmpty)
    }
}

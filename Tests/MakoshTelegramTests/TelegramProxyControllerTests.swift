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
    func testCallProxyRequiresFreshVaultAndFullyAcknowledgedConfiguration() async throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); await c.openAndWait()
        let direct = try await c.currentCallProxy(); XCTAssertNil(direct)
        let target = Target(), id = UUID(); _ = try await c.settingsForConnection(clientID: id); c.register(target, clientID: id)
        await c.confirmAndWait(try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID)))
        await telegramProxyAssertThrows { try await c.currentCallProxy() }
        target.callbacks[0](true)
        let host = try await c.currentCallProxy()?.host; XCTAssertEqual(host, "proxy.example.invalid")
        store.unavailable = true
        await telegramProxyAssertThrows { try await c.currentCallProxy() }
        XCTAssertTrue(target.stopped)
    }
    func testExplicitConfirmationWritesThenAppliesEveryOwnedConnectionAndWaitsForAcknowledgements() async throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault())
        XCTAssertNil(c.enabled); XCTAssertEqual(store.writes, 0)
        await c.openAndWait(); let first = Target(), second = Target()
        let a = UUID(), b = UUID()
        _ = try await c.settingsForConnection(clientID: a); c.register(first, clientID: a)
        _ = try await c.settingsForConnection(clientID: b); c.register(second, clientID: b)
        let confirmation = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        XCTAssertEqual(store.writes, 0); XCTAssertTrue(first.values.isEmpty)
        await c.confirmAndWait(confirmation)
        XCTAssertEqual(store.writes, 1); XCTAssertEqual(c.phase, .applying)
        XCTAssertEqual(first.values.count, 1); XCTAssertEqual(second.values.count, 1)
        first.callbacks[0](true); XCTAssertEqual(c.phase, .applying)
        second.callbacks[0](true); XCTAssertEqual(c.phase, .idle); XCTAssertEqual(c.enabled, true)
        await c.confirmAndWait(confirmation); XCTAssertEqual(store.writes, 1)
    }
    func testStaleEditorAndOpeningConnectionCannotChangeSettings() async throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); await c.openAndWait()
        let stale = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        c.close(); await c.openAndWait(); await c.confirmAndWait(stale); XCTAssertEqual(store.writes, 0)
        let id = UUID(); _ = try await c.settingsForConnection(clientID: id)
        XCTAssertTrue(c.isOpening); XCTAssertNil(c.prepare(.add(draft()), contextID: c.contextID))
        c.unregister(clientID: id); XCTAssertFalse(c.isOpening)
        XCTAssertNotNil(c.prepare(.add(draft()), contextID: c.contextID))
    }
    func testUnknownWriteStopsConnectionsAndExplicitRetryDoesNotRewritePersistedRecord() async throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); await c.openAndWait()
        let target = Target(), id = UUID(); _ = try await c.settingsForConnection(clientID: id); c.register(target, clientID: id)
        let choice = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        store.unavailable = true; await c.confirmAndWait(choice)
        XCTAssertEqual(store.writes, 1); XCTAssertEqual(c.phase, .uncertain); XCTAssertTrue(target.stopped); XCTAssertTrue(target.values.isEmpty)
        store.unavailable = false; await c.openAndWait()
        let retry = try XCTUnwrap(c.prepareRetry(contextID: c.contextID)); await c.confirmAndWait(retry)
        XCTAssertEqual(store.writes, 1); XCTAssertEqual(c.enabled, true); XCTAssertEqual(c.phase, .idle)
    }
    func testFalseOrLateAcknowledgementNeverClaimsAppliedAndCloseDoesNotCancelConfirmedOperation() async throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); await c.openAndWait()
        let target = Target(), id = UUID(); _ = try await c.settingsForConnection(clientID: id); c.register(target, clientID: id)
        await c.confirmAndWait(try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID)))
        c.close(); XCTAssertEqual(c.phase, .applying)
        target.callbacks[0](false); XCTAssertEqual(c.phase, .uncertain); XCTAssertTrue(target.stopped)
        target.callbacks[0](true); XCTAssertEqual(c.phase, .uncertain)
    }
    func testRemovingActiveServerDisablesInsteadOfSelectingAnother() async throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); await c.openAndWait()
        await c.confirmAndWait(try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID)))
        await c.confirmAndWait(try XCTUnwrap(c.prepare(.add(draft("another.example.invalid")), contextID: c.contextID)))
        let selected = try XCTUnwrap(c.selected)
        await c.confirmAndWait(try XCTUnwrap(c.prepare(.remove(selected), contextID: c.contextID)))
        XCTAssertEqual(c.servers.count, 1); XCTAssertNil(c.selected); XCTAssertEqual(c.enabled, false)
        XCTAssertNil(c.prepare(.enabled(true), contextID: c.contextID))
    }
    func testNetworkReplacementDuringApplyRejectsAcknowledgementFromOldNetwork() async throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); await c.openAndWait()
        let old = Target(), replacement = Target(), id = UUID()
        _ = try await c.settingsForConnection(clientID: id); c.register(old, clientID: id)
        await c.confirmAndWait(try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID)))
        c.register(replacement, clientID: id)
        old.callbacks[0](true); XCTAssertEqual(c.phase, .applying)
        replacement.callbacks[0](true); XCTAssertEqual(c.phase, .idle)
        let persisted = try await store.vault().read(); XCTAssertEqual(replacement.values[0], persisted.configuration)
    }
    func testStoppedOpeningCannotRegisterLateNetworkAfterProxyChange() async throws {
        let store = TelegramProxyTestStore(), c = TelegramProxyController(vault: store.vault()); await c.openAndWait()
        let id = UUID(), late = Target()
        _ = try await c.settingsForConnection(clientID: id); c.unregister(clientID: id)
        await c.confirmAndWait(try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID)))
        c.register(late, clientID: id)
        XCTAssertTrue(late.stopped); XCTAssertTrue(late.values.isEmpty)
    }
    func testDelayedConnectionReservesAdmissionAndCancelledResultCannotRegisterLateTarget() async throws {
        let store = TelegramProxyTestStore(), gate = TelegramProxyOperationGate()
        let vault = TelegramProxyVault(lookup: { query in
            let value = store.lookup(query); gate.pauseIfArmed(); return value
        }, add: store.add, update: store.update)
        let c = TelegramProxyController(vault: vault); await c.openAndWait()
        let choice = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        gate.arm(); let id = UUID(), target = Target()
        let connection = Task { _ = try await c.settingsForConnection(clientID: id) }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertTrue(c.isOpening)
        await telegramProxyAssertThrows { try await c.settingsForConnection(clientID: UUID()) }
        c.confirm(choice); XCTAssertEqual(store.writes, 0)
        XCTAssertNil(c.prepare(.add(draft()), contextID: c.contextID))
        c.unregister(clientID: id); gate.release()
        await telegramProxyAssertThrows { try await connection.value }
        c.register(target, clientID: id)
        XCTAssertTrue(target.stopped); XCTAssertFalse(c.isOpening); XCTAssertEqual(c.phase, .idle)
    }
    func testDuplicateDelayedConfirmationWritesOnceAndClosePreservesConfirmedSave() async throws {
        let store = TelegramProxyTestStore(), gate = TelegramProxyOperationGate()
        let vault = TelegramProxyVault(lookup: store.lookup, add: { item in
            gate.pauseIfArmed(); return store.add(item)
        }, update: store.update)
        let c = TelegramProxyController(vault: vault); await c.openAndWait()
        let choice = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        gate.arm(); c.confirm(choice)
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(c.phase, .applying)
        c.confirm(choice)
        await telegramProxyAssertThrows { try await c.settingsForConnection(clientID: UUID()) }
        c.unregister(clientID: UUID()); XCTAssertEqual(c.phase, .applying)
        c.close(); gate.release(); await c.confirmAndWait(choice)
        XCTAssertEqual(store.writes, 1); XCTAssertEqual(c.enabled, true); XCTAssertEqual(c.phase, .idle)
    }
    func testClosingDelayedOpenRejectsItsLatePublication() async throws {
        let store = TelegramProxyTestStore(), gate = TelegramProxyOperationGate()
        let vault = TelegramProxyVault(lookup: { query in
            let value = store.lookup(query); gate.pauseIfArmed(); return value
        }, add: store.add, update: store.update)
        let c = TelegramProxyController(vault: vault)
        gate.arm(); let loading = Task { await c.openAndWait() }
        await fulfillment(of: [gate.started], timeout: 2)
        c.close(); gate.release(); await loading.value
        XCTAssertNil(c.enabled); XCTAssertTrue(c.servers.isEmpty); XCTAssertFalse(c.isOpening)
        await c.openAndWait(); XCTAssertEqual(c.enabled, false)
    }
    func testExternalRecordChangeFailsClosedWithoutPublishingDirectSettings() async throws {
        let store = TelegramProxyTestStore(), vault = store.vault()
        var configuration = TelegramProxyConfiguration(), d = draft()
        d.host = "selected.example.invalid"
        let server = try TelegramProxyServer(draft: d)
        configuration.enabled = true; configuration.servers = [server]; configuration.selected = server.id
        let persisted = try await vault.save(configuration, expected: .init(configuration: .init(), token: nil))
        let c = TelegramProxyController(vault: vault); await c.openAndWait()
        let target = Target(), id = UUID()
        let source = try await c.settingsForConnection(clientID: id); c.register(target, clientID: id)
        var directWasPublished = false
        let disposable = source.start(next: { if !$0.enabled { directWasPublished = true } })
        defer { disposable.dispose() }
        configuration.enabled = false
        _ = try await store.vault().save(configuration, expected: persisted)
        await telegramProxyAssertThrows { try await c.currentCallProxy() }
        XCTAssertTrue(target.stopped); XCTAssertEqual(c.phase, .uncertain)
        XCTAssertFalse(directWasPublished); XCTAssertEqual(c.enabled, true)
    }

    func testReplacementDuringDelayedSaveOnlyAppliesConfirmedRecord() async throws {
        let store = TelegramProxyTestStore(), gate = TelegramProxyOperationGate()
        let vault = TelegramProxyVault(lookup: store.lookup, add: { item in
            gate.pauseIfArmed(); return store.add(item)
        }, update: store.update)
        let c = TelegramProxyController(vault: vault); await c.openAndWait()
        let old = Target(), replacement = Target(), id = UUID()
        _ = try await c.settingsForConnection(clientID: id); c.register(old, clientID: id)
        let choice = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        gate.arm(); c.confirm(choice)
        await fulfillment(of: [gate.started], timeout: 2)
        c.register(replacement, clientID: id)
        XCTAssertTrue(replacement.values.isEmpty); XCTAssertTrue(old.values.isEmpty)
        gate.release(); await c.confirmAndWait(choice)
        XCTAssertEqual(replacement.values.count, 1)
        XCTAssertTrue(replacement.values[0].enabled)
        XCTAssertEqual(replacement.values[0].servers.first?.host, "proxy.example.invalid")
        XCTAssertTrue(old.values.isEmpty); XCTAssertEqual(c.phase, .applying)
        replacement.callbacks[0](true); XCTAssertEqual(c.phase, .idle)
    }

    func testLateCallLookupCannotInvalidateNewerConfirmedOperation() async throws {
        let store = TelegramProxyTestStore(), gate = TelegramProxyOperationGate()
        let vault = TelegramProxyVault(lookup: { query in
            let value = store.lookup(query); gate.pauseIfArmed(); return value
        }, add: store.add, update: store.update)
        let c = TelegramProxyController(vault: vault); await c.openAndWait()
        let target = Target(), id = UUID()
        _ = try await c.settingsForConnection(clientID: id); c.register(target, clientID: id)
        let choice = try XCTUnwrap(c.prepare(.add(draft()), contextID: c.contextID))
        gate.arm(); let oldLookup = Task { try await c.currentCallProxy() }
        await fulfillment(of: [gate.started], timeout: 2)
        c.confirm(choice); gate.release()
        await telegramProxyAssertThrows { try await oldLookup.value }
        await c.confirmAndWait(choice)
        XCTAssertFalse(target.stopped); XCTAssertEqual(c.phase, .applying)
        XCTAssertEqual(target.values.count, 1); XCTAssertEqual(c.enabled, true)
        target.callbacks[0](true)
        let proxy = try await c.currentCallProxy(); XCTAssertEqual(proxy?.host, "proxy.example.invalid")
    }

}

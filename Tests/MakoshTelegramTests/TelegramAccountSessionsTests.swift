import XCTest
import TelegramApi
@testable import MakoshTelegram

final class TelegramAccountSessionsTests: XCTestCase {
    static func session(_ id: Int64, active: Int32 = 100, created: Int32 = 10, pending: Bool = false,
        secret: Bool = true, calls: Bool = true) -> TelegramAccountSession {
        .init(id: id, device: "Synthetic device", platform: "Synthetic OS", systemVersion: "1", app: "QA",
            appVersion: "1", ip: "192.0.2.1", country: "Test", region: "Test", apiID: 123,
            created: created, active: active, official: false, pending: pending, acceptsSecretChats: secret, acceptsCalls: calls)
    }
    static func snapshot(_ sessions: [TelegramAccountSession] = [session(0), session(9)], account: Int64 = 1, ttl: Int32 = 31) -> TelegramSessionsSnapshot {
        .init(accountID: account, sessions: sessions, ttlDays: ttl)
    }
    private func wire(hash: Int64, flags: Int32) -> Api.Authorization {
        .authorization(flags: flags, hash: hash, deviceModel: "Synthetic device", platform: "Synthetic OS", systemVersion: "1",
            apiId: 123, appName: "QA", appVersion: "1", dateCreated: 10, dateActive: 100, ip: "192.0.2.1", country: "Test", region: "Test")
    }
    func testNativeAuthorizationsNormalizeCurrentAndInvertDisabledBits() throws {
        let result = try XCTUnwrap(telegramSessionsSnapshot(.authorizations(authorizationTtlDays: 31,
            authorizations: [wire(hash: 55, flags: 1 | 2), wire(hash: -9, flags: 4 | 8 | 16)]), accountID: 1))
        XCTAssertEqual(result.current?.id, 0); XCTAssertEqual(result.current?.official, true)
        XCTAssertEqual(result.current?.acceptsSecretChats, true); XCTAssertEqual(result.current?.acceptsCalls, true)
        XCTAssertEqual(result.pending.map(\.id), [-9]); XCTAssertEqual(result.pending.first?.acceptsSecretChats, false)
        XCTAssertEqual(result.pending.first?.acceptsCalls, false); XCTAssertEqual(result.ttlDays, 31)
    }
    func testMalformedAuthorizationListsFailClosed() {
        for list in [[wire(hash: 9, flags: 0)], [wire(hash: 1, flags: 1), wire(hash: 2, flags: 1)],
            [wire(hash: 1, flags: 1), wire(hash: 9, flags: 0), wire(hash: 9, flags: 0)], [wire(hash: 0, flags: 0)]] {
            XCTAssertNil(telegramSessionsSnapshot(.authorizations(authorizationTtlDays: 31, authorizations: list), accountID: 1))
        }
    }
    func testFreshAdmissionRejectsReplacedDeviceAndCurrentTerminationButAllowsActivityAdvance() {
        let old = Self.snapshot(), target = Self.session(9)
        XCTAssertTrue(old.permits(.terminate(target))); XCTAssertFalse(old.permits(.terminate(Self.session(0))))
        XCTAssertTrue(telegramAdmitSessionChange(expected: old, current: Self.snapshot([Self.session(0), Self.session(9, active: 200)]), change: .terminate(target)))
        XCTAssertFalse(telegramAdmitSessionChange(expected: old, current: Self.snapshot([Self.session(0), Self.session(9, created: 20)]), change: .terminate(target)))
        XCTAssertFalse(telegramAdmitSessionChange(expected: old, current: Self.snapshot(account: 2), change: .terminate(target)))
        XCTAssertFalse(telegramAdmitSessionChange(expected: old, current: Self.snapshot([Self.session(0)]), change: .terminate(target)))
    }
    func testTerminateAllRequiresSameConfirmedSetAndTTLUsesFreshBasis() {
        let old = Self.snapshot()
        XCTAssertTrue(telegramAdmitSessionChange(expected: old, current: old, change: .terminateOthers))
        XCTAssertFalse(telegramAdmitSessionChange(expected: old, current: Self.snapshot([Self.session(0), Self.session(9), Self.session(10)]), change: .terminateOthers))
        XCTAssertTrue(telegramAdmitSessionChange(expected: old, current: old, change: .ttl(93)))
        XCTAssertFalse(telegramAdmitSessionChange(expected: old, current: Self.snapshot(ttl: 7), change: .ttl(93)))
        for days: Int32 in [0, 1, 30, 365] { XCTAssertFalse(old.permits(.ttl(days))) }
    }
    func testSettingsRejectChangedBasisAndPendingSession() {
        let old = Self.snapshot(), target = Self.session(9)
        XCTAssertTrue(old.permits(.secretChats(target, false))); XCTAssertTrue(old.permits(.calls(target, false)))
        XCTAssertFalse(old.permits(.calls(target, true)))
        XCTAssertFalse(telegramAdmitSessionChange(expected: old, current: Self.snapshot([Self.session(0), Self.session(9, calls: false)]), change: .calls(target, false)))
        XCTAssertFalse(Self.snapshot([Self.session(0), Self.session(9, pending: true)]).permits(.calls(Self.session(9, pending: true), false)))
    }
    func testServerRejectionAndUncertainTransportRemainDistinct() {
        XCTAssertEqual(telegramSessionWriteError(code: 406, change: .terminateOthers), .freshReset)
        for code: Int32 in [-500, -1, 0, 500, 503] { XCTAssertEqual(telegramSessionWriteError(code: code, change: .terminateOthers), .uncertain) }
        for code: Int32 in [400, 401, 403, 420] { XCTAssertEqual(telegramSessionWriteError(code: code, change: .terminateOthers), .failed) }
    }
    func testFreshLoginTerminationRejectionIsNotUsedForTTLOrAcceptanceErrors() {
        let target = Self.session(9)
        XCTAssertEqual(telegramSessionWriteError(code: 406, change: .terminate(target)), .freshReset)
        for change: TelegramSessionChange in [.ttl(93), .secretChats(target, false), .calls(target, false)] {
            XCTAssertEqual(telegramSessionWriteError(code: 406, change: change), .failed)
        }
    }
}

@MainActor final class TelegramSessionsControllerTests: XCTestCase {
    func testSyntheticWorkspaceDevicesChangeWithoutOpeningAnAccount() throws {
        let model = TelegramModel.syntheticPreview()
        model.accountSessions.open()
        let snapshot = try XCTUnwrap(model.accountSessions.snapshot)
        XCTAssertTrue(model.isSyntheticPreview); XCTAssertEqual(snapshot.sessions.count, 3)
        let target = try XCTUnwrap(snapshot.others.first)
        XCTAssertTrue(model.accountSessions.apply(.calls(target, false), contextID: model.accountSessions.contextID))
        XCTAssertEqual(model.accountSessions.snapshot?.others.first?.acceptsCalls, false)
        XCTAssertTrue(model.accountSessions.apply(.terminate(target), contextID: model.accountSessions.contextID) == false)
        let updated = try XCTUnwrap(model.accountSessions.snapshot?.others.first)
        XCTAssertTrue(model.accountSessions.apply(.terminate(updated), contextID: model.accountSessions.contextID))
        XCTAssertEqual(model.accountSessions.snapshot?.others.count, 0)
    }
    private final class Request: TelegramSessionsRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramSessionsProvider {
        let accountID: Int64
        init(_ id: Int64 = 1) { accountID = id }
        var reads: [(Request, @MainActor (Result<TelegramSessionsSnapshot, TelegramSessionsError>) -> Void)] = []
        var writes: [(Request, @MainActor (Result<Void, TelegramSessionsError>) -> Void)] = []
        func load(receive: @escaping @MainActor (Result<TelegramSessionsSnapshot, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
            let r = Request(); reads.append((r, receive)); return r
        }
        func apply(_ change: TelegramSessionChange, expected: TelegramSessionsSnapshot,
            receive: @escaping @MainActor (Result<Void, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
            let r = Request(); writes.append((r, receive)); return r
        }
    }
    func testAccountRebindingAndClosingRejectLateReadsAndWrites() throws {
        let value = TelegramSessionsController(), p = Provider(), other = Provider(2)
        value.bind(p); value.open(); XCTAssertEqual(p.reads.count, 1); guard p.reads.count == 1 else { return }
        p.reads[0].1(.success(TelegramAccountSessionsTests.snapshot()))
        XCTAssertNotNil(value.snapshot)
        let oldContext = value.contextID
        XCTAssertTrue(value.apply(.terminateOthers, contextID: oldContext))
        value.bind(other); value.open()
        XCTAssertTrue(p.writes[0].0.cancelled)
        p.reads[0].1(.success(TelegramAccountSessionsTests.snapshot())); p.writes[0].1(.success(()))
        XCTAssertNil(value.snapshot); XCTAssertFalse(value.apply(.terminateOthers, contextID: oldContext))
        other.reads[0].1(.success(TelegramAccountSessionsTests.snapshot(account: 1)))
        XCTAssertEqual(value.status, .failed); XCTAssertNil(value.snapshot)
        value.close(); XCTAssertEqual(value.status, .idle)
    }
    func testTimeoutNeverResendsAndRequiresExplicitReconciliation() throws {
        let value = TelegramSessionsController(), p = Provider()
        value.bind(p); value.open(); XCTAssertEqual(p.reads.count, 1); guard p.reads.count == 1 else { return }
        p.reads[0].1(.success(TelegramAccountSessionsTests.snapshot()))
        XCTAssertTrue(value.apply(.terminateOthers, contextID: value.contextID)); guard p.writes.count == 1 else { return }
        XCTAssertFalse(value.apply(.terminateOthers, contextID: value.contextID))
        value.timeoutMutation(); XCTAssertTrue(p.writes[0].0.cancelled)
        p.writes[0].1(.success(())); XCTAssertEqual(value.mutationStatus, .uncertain)
        value.close(); value.open(); p.reads[1].1(.success(TelegramAccountSessionsTests.snapshot()))
        XCTAssertEqual(value.mutationStatus, .uncertain); XCTAssertFalse(value.apply(.terminateOthers, contextID: value.contextID))
        value.refresh(); p.reads[2].1(.success(TelegramAccountSessionsTests.snapshot()))
        XCTAssertEqual(value.mutationStatus, .idle); XCTAssertEqual(p.writes.count, 1)
    }
    func testRefreshInvalidatesConfirmationAndAckReloadsWithoutOptimisticRemoval() throws {
        let value = TelegramSessionsController(), p = Provider()
        value.bind(p); value.open(); XCTAssertEqual(p.reads.count, 1); guard p.reads.count == 1 else { return }
        p.reads[0].1(.success(TelegramAccountSessionsTests.snapshot()))
        let captured = value.contextID
        value.refresh(); p.reads[1].1(.success(TelegramAccountSessionsTests.snapshot()))
        XCTAssertFalse(value.apply(.terminateOthers, contextID: captured))
        XCTAssertTrue(value.apply(.terminateOthers, contextID: value.contextID)); guard p.writes.count == 1 else { return }
        XCTAssertEqual(value.snapshot?.sessions.count, 2)
        p.writes[0].1(.success(())); XCTAssertEqual(value.mutationStatus, .saved)
        p.reads[2].1(.success(TelegramAccountSessionsTests.snapshot([TelegramAccountSessionsTests.session(0)])))
        XCTAssertEqual(value.snapshot?.sessions.map(\.id), [0])
    }
}

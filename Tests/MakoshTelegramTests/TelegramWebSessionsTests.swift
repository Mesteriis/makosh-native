import XCTest
import TelegramApi
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramWebSessionsTests: XCTestCase {
    static func session(_ id: Int64 = 9, created: Int32 = 10, active: Int32 = 20, domain: String = "test.example") -> TelegramWebSession {
        .init(id: id, botID: 42, domain: domain, browser: "Test Browser", platform: "Test OS", created: created, active: active, ip: "192.0.2.1", region: "Test")
    }
    static func snapshot(_ sessions: [TelegramWebSession]? = nil, account: Int64 = 1) -> TelegramWebSessionsSnapshot {
        .init(accountID: account, sessions: sessions ?? [session()])
    }
    func testNativeMappingRejectsDuplicateAndMalformedWebIdentities() throws {
        let a = Api.WebAuthorization.webAuthorization(hash: -9, botId: 42, domain: "test.example", browser: "Test Browser", platform: "Test OS", dateCreated: 10, dateActive: 20, ip: "192.0.2.1", region: "Test")
        let mapped = try XCTUnwrap(telegramWebSessionsSnapshot(.webAuthorizations(authorizations: [a], users: []), accountID: 1))
        XCTAssertEqual(mapped.sessions.first?.id, -9); XCTAssertEqual(mapped.sessions.first?.botID, 42)
        XCTAssertNil(telegramWebSessionsSnapshot(.webAuthorizations(authorizations: [a, a], users: []), accountID: 1))
        XCTAssertTrue(Self.snapshot([]).isValid)
        XCTAssertFalse(Self.snapshot([Self.session(0)]).isValid)
        XCTAssertFalse(Self.snapshot([Self.session(domain: "\u{0}bad")]).isValid)
    }
    func testTerminationRevalidatesConfirmedIdentityAndEntireSet() {
        let old = Self.snapshot(), target = Self.session()
        XCTAssertTrue(telegramAdmitWebSessionChange(expected: old, current: Self.snapshot([Self.session(active: 30)]), change: .terminate(target)))
        XCTAssertFalse(telegramAdmitWebSessionChange(expected: old, current: Self.snapshot([Self.session(created: 11)]), change: .terminate(target)))
        XCTAssertFalse(telegramAdmitWebSessionChange(expected: old, current: Self.snapshot(account: 2), change: .terminate(target)))
        XCTAssertFalse(telegramAdmitWebSessionChange(expected: old, current: Self.snapshot([target, Self.session(10)]), change: .terminateAll))
        XCTAssertFalse(Self.snapshot([]).permits(.terminateAll))
        XCTAssertFalse(old.permits(.terminate(Self.session(10))))
    }
    func testNativeRPCUsesExactHashAndNeverBlocksTheBot() throws {
        let one = try XCTUnwrap(telegramWebSessionRPC(.terminate(Self.session(-9))))
        XCTAssertEqual(one.0.name, "account.resetWebAuthorization")
        XCTAssertEqual(one.0.parameters.first { $0.0 == "hash" }?.1 as? String, "-9")
        XCTAssertEqual(telegramWebSessionRPC(.terminateAll)?.0.name, "account.resetWebAuthorizations")
        XCTAssertNil(telegramWebSessionRPC(.terminate(Self.session(0))))
    }
    func testEmptyReadOrWriteCannotBecomeSuccess() {
        for emptyRead in [true, false] {
            let done = expectation(description: "empty completion")
            let request = telegramPerformWebSessionChange(expected: Self.snapshot(), change: .terminateAll,
                load: { emptyRead ? .complete() : .single(Self.snapshot()) }, perform: { _ in .complete() }).start(
                    next: { XCTFail("Missing ACK accepted") }, error: { XCTAssertEqual($0, .uncertain); done.fulfill() },
                    completed: { XCTFail("Missing ACK completed"); done.fulfill() })
            wait(for: [done], timeout: 2); request.dispose()
        }
    }
    func testFreshSetMismatchStopsRPC() {
        let done = expectation(description: "changed set"), old = Self.snapshot()
        var performed = false
        let request = telegramPerformWebSessionChange(expected: old, change: .terminateAll,
            load: { .single(Self.snapshot([Self.session(), Self.session(10)])) }, perform: { _ in performed = true; return .single(()) }).start(
                error: { XCTAssertEqual($0, .changed); done.fulfill() })
        wait(for: [done], timeout: 2); request.dispose(); XCTAssertFalse(performed)
    }
}

@MainActor final class TelegramWebSessionsControllerTests: XCTestCase {
    private final class Request: TelegramSessionsRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramWebSessionsProvider {
        let accountID: Int64
        init(_ id: Int64 = 1) { accountID = id }
        var reads: [(Request, @MainActor (Result<TelegramWebSessionsSnapshot, TelegramSessionsError>) -> Void)] = []
        var writes: [(Request, @MainActor (Result<Void, TelegramSessionsError>) -> Void)] = []
        func load(receive: @escaping @MainActor (Result<TelegramWebSessionsSnapshot, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
            let r = Request(); reads.append((r, receive)); return r
        }
        func apply(_ change: TelegramWebSessionChange, expected: TelegramWebSessionsSnapshot, receive: @escaping @MainActor (Result<Void, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
            let r = Request(); writes.append((r, receive)); return r
        }
    }
    func testClosingDuringWritePreservesUncertaintyUntilExplicitRefresh() throws {
        let c = TelegramWebSessionsController(), p = Provider()
        c.bind(p); c.open(); p.reads[0].1(.success(TelegramWebSessionsTests.snapshot()))
        let context = c.contextID
        XCTAssertTrue(c.apply(.terminateAll, contextID: context))
        c.close(); XCTAssertTrue(p.writes[0].0.cancelled); p.writes[0].1(.success(()))
        c.open(); p.reads[1].1(.success(TelegramWebSessionsTests.snapshot()))
        XCTAssertEqual(c.mutationStatus, .uncertain); XCTAssertFalse(c.apply(.terminateAll, contextID: c.contextID))
        c.refresh(); p.reads[2].1(.success(TelegramWebSessionsTests.snapshot()))
        XCTAssertEqual(c.mutationStatus, .idle); XCTAssertFalse(c.apply(.terminateAll, contextID: context))
    }
    func testRebindAndMalformedReadRejectLateOrForeignResults() {
        let c = TelegramWebSessionsController(), p = Provider(), other = Provider(2)
        c.bind(p); c.open(); c.bind(other); c.open()
        XCTAssertTrue(p.reads[0].0.cancelled)
        p.reads[0].1(.success(TelegramWebSessionsTests.snapshot())); XCTAssertNil(c.snapshot)
        other.reads[0].1(.success(TelegramWebSessionsTests.snapshot())); XCTAssertEqual(c.status, .failed)
        XCTAssertNil(c.snapshot)
    }
    func testTimeoutRejectsLateAckAndDoesNotRetry() {
        let c = TelegramWebSessionsController(), p = Provider()
        c.bind(p); c.open(); p.reads[0].1(.success(TelegramWebSessionsTests.snapshot()))
        XCTAssertTrue(c.apply(.terminateAll, contextID: c.contextID)); c.timeoutMutation()
        XCTAssertTrue(p.writes[0].0.cancelled); p.writes[0].1(.success(()))
        XCTAssertEqual(c.mutationStatus, .uncertain); XCTAssertEqual(p.writes.count, 1)
        XCTAssertFalse(c.apply(.terminateAll, contextID: c.contextID))
    }
    func testFailedRefreshDoesNotRemoveUncertainBarrier() {
        let c = TelegramWebSessionsController(), p = Provider()
        c.bind(p); c.open(); p.reads[0].1(.success(TelegramWebSessionsTests.snapshot()))
        XCTAssertTrue(c.apply(.terminateAll, contextID: c.contextID)); p.writes[0].1(.failure(.uncertain))
        c.refresh(); p.reads[1].1(.failure(.failed))
        XCTAssertEqual(c.status, .failed); XCTAssertEqual(c.mutationStatus, .uncertain)
        XCTAssertFalse(c.apply(.terminateAll, contextID: c.contextID)); XCTAssertEqual(p.writes.count, 1)
    }
    func testAcknowledgementRequiresPostRead() {
        let c = TelegramWebSessionsController(), p = Provider()
        c.bind(p); c.open(); p.reads[0].1(.success(TelegramWebSessionsTests.snapshot()))
        XCTAssertTrue(c.apply(.terminateAll, contextID: c.contextID)); p.writes[0].1(.success(()))
        XCTAssertEqual(c.status, .loading); XCTAssertEqual(c.snapshot?.sessions.count, 1)
        p.reads[1].1(.success(TelegramWebSessionsTests.snapshot([])))
        XCTAssertEqual(c.snapshot?.sessions.count, 0)
    }
}

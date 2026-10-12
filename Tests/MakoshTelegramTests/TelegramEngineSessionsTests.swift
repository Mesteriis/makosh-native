import XCTest
import TelegramApi
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramEngineSessionsTests: XCTestCase {
    func testEmptyFreshReadOrWriteCompletionIsNeverAnAcknowledgement() {
        let old = TelegramAccountSessionsTests.snapshot()
        for emptyRead in [true, false] {
            let done = expectation(description: "missing acknowledgement")
            let disposable = telegramPerformSessionChange(expected: old, change: .terminateOthers,
                load: { emptyRead ? .complete() : .single(old) }, perform: { _ in .complete() }).start(
                    next: { XCTFail("Empty RPC acknowledged") }, error: { error in XCTAssertEqual(error, .uncertain); done.fulfill() },
                    completed: { XCTFail("Empty RPC completed as success"); done.fulfill() })
            wait(for: [done], timeout: 2); disposable.dispose()
        }
    }
    func testNativeRPCSeparatesTerminationTTLAndInvertsAcceptanceFlags() throws {
        let target = TelegramAccountSessionsTests.session(9)
        let cases: [(TelegramSessionChange, String, String, String)] = [
            (.terminate(target), "account.resetAuthorization", "hash", "9"),
            (.terminateOthers, "auth.resetAuthorizations", "", ""),
            (.ttl(93), "account.setAuthorizationTTL", "authorizationTtlDays", "93"),
            (.secretChats(target, false), "account.changeAuthorizationSettings", "flags", "1"),
            (.calls(target, false), "account.changeAuthorizationSettings", "flags", "2")]
        for (change, name, field, value) in cases {
            let rpc = try XCTUnwrap(telegramSessionRPC(change))
            XCTAssertEqual(rpc.0.name, name)
            if !field.isEmpty { XCTAssertEqual(rpc.0.parameters.first { $0.0 == field }?.1 as? String, value) }
        }
        for accepts in [false, true] {
            let secret = BufferReader(try XCTUnwrap(telegramSessionRPC(.secretChats(target, accepts))).1)
            XCTAssertEqual(secret.readInt32(), 1089766498); XCTAssertEqual(secret.readInt32(), 1); XCTAssertEqual(secret.readInt64(), 9)
            XCTAssertEqual(secret.readInt32(), accepts ? -1132882121 : -1720552011)
            let calls = BufferReader(try XCTUnwrap(telegramSessionRPC(.calls(target, accepts))).1)
            XCTAssertEqual(calls.readInt32(), 1089766498); XCTAssertEqual(calls.readInt32(), 2); XCTAssertEqual(calls.readInt64(), 9)
            XCTAssertEqual(calls.readInt32(), accepts ? -1132882121 : -1720552011)
        }
        XCTAssertNil(telegramSessionRPC(.terminate(TelegramAccountSessionsTests.session(0))))
        XCTAssertNil(telegramSessionRPC(.ttl(0)))
        XCTAssertTrue(telegramSessionAcknowledged(.boolTrue)); XCTAssertFalse(telegramSessionAcknowledged(.boolFalse))
    }
    func testFreshNativeAdmissionBlocksUnconfirmedDeviceSetBeforeRPC() {
        let old = TelegramAccountSessionsTests.snapshot(), done = expectation(description: "fresh admission")
        var reachedRPC = false
        let disposable = telegramPerformSessionChange(expected: old, change: .terminateOthers, load: {
            .single(TelegramAccountSessionsTests.snapshot([TelegramAccountSessionsTests.session(0), TelegramAccountSessionsTests.session(10)]))
        }, perform: { _ in reachedRPC = true; return .single(()) }).start(error: { error in
            XCTAssertEqual(error, .changed); done.fulfill()
        }, completed: { XCTFail("Changed set accepted"); done.fulfill() })
        wait(for: [done], timeout: 2); disposable.dispose(); XCTAssertFalse(reachedRPC)
    }
    func testFreshAdmissionSendsExactConfirmedChangeAndPropagatesUncertainResult() {
        let old = TelegramAccountSessionsTests.snapshot(), done = expectation(description: "write error")
        let change = TelegramSessionChange.calls(TelegramAccountSessionsTests.session(9), false)
        var received: TelegramSessionChange?
        let disposable = telegramPerformSessionChange(expected: old, change: change, load: { .single(old) }, perform: { value in
            received = value; return .fail(.uncertain)
        }).start(error: { error in XCTAssertEqual(error, .uncertain); done.fulfill() }, completed: { XCTFail("Missing error"); done.fulfill() })
        wait(for: [done], timeout: 2); disposable.dispose(); XCTAssertEqual(received, change)
    }
}

import XCTest
import TelegramApi
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramEngineGlobalPrivacyTests: XCTestCase {
    func testFreshGlobalConflictOrRevokedCapabilityStopsBeforeWrite() throws {
        let old = TelegramGlobalPrivacyTests.initial
        let next = try XCTUnwrap(old.replacing(.messagePolicy(.contactsAndPremium)))
        let change = TelegramGlobalPrivacyChange(expected: old, proposed: next)
        for mode in 0..<3 {
            let done = expectation(description: "Refused fresh global admission")
            var writes = 0
            let d = telegramPerformGlobalPrivacyChange(accountID: mode == 0 ? 2 : 1, expectedAccountID: 1, change: change,
                load: { .single((mode == 1 ? next : old, mode == 2 ? TelegramGlobalPrivacyTests.basic : TelegramGlobalPrivacyTests.premium)) },
                perform: { _ in writes += 1; return .single(next) }).start(next: { _ in XCTFail("Refusal acknowledged") },
                    error: { XCTAssertEqual($0, mode == 2 ? .unavailable : .changed); done.fulfill() },
                    completed: { XCTFail("Missing refusal"); done.fulfill() })
            wait(for: [done], timeout: 2); d.dispose(); XCTAssertEqual(writes, 0)
        }
    }
    func testGlobalWriteUsesExactConfirmedPayloadAndRequiresMatchingAcknowledgement() throws {
        let old = TelegramGlobalPrivacyTests.initial
        let next = try XCTUnwrap(old.replacing(.hideReadTime(true)))
        let done = expectation(description: "Exact global acknowledgement")
        var sent: TelegramGlobalPrivacySetting?
        let d = telegramPerformGlobalPrivacyChange(accountID: 1, expectedAccountID: 1, change: .init(expected: old, proposed: next),
            load: { .single((old, TelegramGlobalPrivacyTests.basic)) }, perform: { sent = $0; return .single(next) }).start(
                next: { XCTAssertEqual($0, next) }, error: { _ in XCTFail("Confirmed ACK refused"); done.fulfill() }, completed: { done.fulfill() })
        wait(for: [done], timeout: 2); d.dispose(); XCTAssertEqual(sent, next)
        let rpc = try XCTUnwrap(telegramGlobalPrivacyRPC(next))
        XCTAssertEqual(rpc.0.name, "account.setGlobalPrivacySettings")
        let reader = BufferReader(rpc.1); XCTAssertEqual(reader.readInt32(), 517647042)
        let signature = try XCTUnwrap(reader.readInt32())
        let native = try XCTUnwrap(Api.parse(reader, signature: signature) as? Api.GlobalPrivacySettings)
        XCTAssertEqual(TelegramGlobalPrivacySetting(native), next)
    }
    func testEmptyReadOrMissingOrAlteredGlobalAcknowledgementRemainsUncertain() throws {
        let old = TelegramGlobalPrivacyTests.initial, next = try XCTUnwrap(TelegramGlobalPrivacyTests.initial.replacing(.hideReadTime(true)))
        for mode in 0..<3 {
            let done = expectation(description: "Uncertain global result")
            let d = telegramPerformGlobalPrivacyChange(accountID: 1, expectedAccountID: 1, change: .init(expected: old, proposed: next),
                load: { mode == 0 ? .complete() : .single((old, TelegramGlobalPrivacyTests.premium)) },
                perform: { _ in mode == 1 ? .complete() : .single(old) }).start(next: { _ in XCTFail("Missing/altered ACK accepted") },
                    error: { XCTAssertEqual($0, .uncertain); done.fulfill() }, completed: { XCTFail("False success"); done.fulfill() })
            wait(for: [done], timeout: 2); d.dispose()
        }
    }
}

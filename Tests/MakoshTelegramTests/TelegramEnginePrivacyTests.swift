import XCTest
import TelegramApi
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramEnginePrivacyTests: XCTestCase {
    private func user(_ id: Int64, hash: Int64? = 70, flags: Int32 = 1) -> Api.User {
        .user(flags: flags, flags2: 0, id: id, accessHash: hash, firstName: nil, lastName: nil, username: nil,
            phone: nil, photo: nil, status: nil, botInfoVersion: nil, restrictionReason: nil, botInlinePlaceholder: nil,
            langCode: nil, emojiStatus: nil, usernames: nil, storiesMaxId: nil, color: nil, profileColor: nil,
            botActiveUsers: nil, botVerificationIcon: nil, sendPaidMessagesStars: nil)
    }
    func testFreshUserHashesNeverBorrowMinOrMissingIdentityOrAcceptDuplicates() throws {
        let result = try XCTUnwrap(telegramPrivacyUserHashes([user(7), user(8, hash: 80, flags: 1 | (1 << 20)), .userEmpty(id: 9)]))
        XCTAssertEqual(result, [7: 70])
        XCTAssertNil(telegramPrivacyUserHashes([user(7), user(7, hash: 80)]))
        XCTAssertNil(telegramPrivacyUserHashes([user(0)]))
        XCTAssertEqual(telegramPrivacyUserHashes([user(7, hash: nil)]), [:])
    }
    func testFreshPrivacyConflictStopsBeforeRPC() {
        let old = TelegramPrivacyTests.setting(), change = TelegramPrivacyChange(expected: old, audience: .nobody)
        var called = false
        let done = expectation(description: "conflict")
        let d = telegramPerformPrivacyChange(accountID: 1, expectedAccountID: 1, change: change,
            load: { .single(TelegramPrivacyTests.setting([.everybody])) }, perform: { _ in called = true; return .single(old) }).start(
                error: { XCTAssertEqual($0, .changed); done.fulfill() }, completed: { XCTFail("Conflict accepted"); done.fulfill() })
        wait(for: [done], timeout: 2); d.dispose(); XCTAssertFalse(called)
    }
    func testExactConfirmedRulesAreSentAndServerAcknowledgementIsRequired() {
        let old = TelegramPrivacyTests.setting(), change = TelegramPrivacyChange(expected: old, audience: .nobody)
        let wanted = TelegramPrivacyTests.setting([.allowUsers([7]), .denyChats([9]), .nobody, .premium])
        let done = expectation(description: "ACK")
        var received: TelegramPrivacySetting?
        let d = telegramPerformPrivacyChange(accountID: 1, expectedAccountID: 1, change: change,
            load: { .single(old) }, perform: { received = $0; return .single(wanted) }).start(
                next: { XCTAssertEqual($0, wanted) }, error: { _ in XCTFail("ACK rejected"); done.fulfill() }, completed: { done.fulfill() })
        wait(for: [done], timeout: 2); d.dispose(); XCTAssertEqual(received, wanted)
    }
    func testEmptyOrMismatchingAcknowledgementNeverReportsSuccess() {
        let old = TelegramPrivacyTests.setting(), change = TelegramPrivacyChange(expected: old, audience: .nobody)
        for mode in 0..<3 {
            let done = expectation(description: "unresolved")
            let d = telegramPerformPrivacyChange(accountID: 1, expectedAccountID: 1, change: change,
                load: { mode == 0 ? .complete() : .single(old) }, perform: { _ in mode == 1 ? .complete() : .single(TelegramPrivacyTests.setting([.nobody])) }).start(
                    next: { _ in XCTFail("Missing/changed ACK accepted") }, error: { XCTAssertEqual($0, .uncertain); done.fulfill() },
                    completed: { XCTFail("No ACK"); done.fulfill() })
            wait(for: [done], timeout: 2); d.dispose()
        }
    }
    func testNativeWriteRPCUsesTypedPrivacyKeyAndPreservedExceptionRules() throws {
        let value = TelegramPrivacyTests.setting([.denyChats([9]), .nobody], kind: .phoneNumber)
        let rpc = try XCTUnwrap(telegramPrivacyRPC(value, userHashes: [:], selfID: 1))
        XCTAssertEqual(rpc.0.name, "account.setPrivacy")
        let reader = BufferReader(rpc.1)
        XCTAssertEqual(reader.readInt32(), -906486552)
        guard let signature = reader.readInt32(), let key = Api.parse(reader, signature: signature) as? Api.InputPrivacyKey else { return XCTFail("Missing key") }
        XCTAssertEqual(key.descriptionFields().0, "inputPrivacyKeyPhoneNumber")
        XCTAssertEqual(reader.readInt32(), 481674261); XCTAssertEqual(reader.readInt32(), 2)
        guard let ruleSignature = reader.readInt32(), let rule = Api.parse(reader, signature: ruleSignature) as? Api.InputPrivacyRule,
              case let .inputPrivacyValueDisallowChatParticipants(ids) = rule else { return XCTFail("Exception lost") }
        XCTAssertEqual(ids, [9])
    }
}

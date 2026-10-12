import XCTest
@testable import MakoshTelegram

final class TelegramPrivacyExceptionTests: XCTestCase {
    func testMovingToAllowRemovesOnlyMatchingOppositeExceptionsAndPreservesSpecialRules() throws {
        let old = TelegramPrivacyTests.setting([.denyUsers([7,8]), .denyChats([9,10]), .contacts, .nobody, .premium, .denyBots])
        let result = try XCTUnwrap(old.replacingExceptions(.allow, peers: [.user(7), .chat(9)]))
        XCTAssertEqual(result.rules, [.denyUsers([8]), .denyChats([10]), .allowUsers([7]), .allowChats([9]), .contacts, .nobody, .premium, .denyBots])
        XCTAssertEqual(result.audience, .contacts)
    }
    func testReplacingMembershipAndRemovingAllKeepOtherRuleOrder() throws {
        let old = TelegramPrivacyTests.setting([.allowUsers([7]), .premium, .allowChats([9]), .denyUsers([8]), .contacts])
        let changed = try XCTUnwrap(old.replacingExceptions(.allow, peers: [.chat(10), .user(11)]))
        XCTAssertEqual(changed.rules, [.allowUsers([11]), .allowChats([10]), .premium, .denyUsers([8]), .contacts])
        let empty = try XCTUnwrap(old.replacingExceptions(.allow, peers: []))
        XCTAssertEqual(empty.rules, [.premium, .denyUsers([8]), .contacts])
        XCTAssertNil(old.replacingExceptions(.allow, peers: [.user(7), .chat(9)]))
    }
    func testInvalidDuplicateOversizedOrUnsupportedMembershipIsRefused() {
        let old = TelegramPrivacyTests.setting()
        for peers: [TelegramPrivacyPeerID] in [[.user(0)], [.chat(-1)], [.user(7), .user(7)], (1...1025).map { .user(Int64($0)) }] {
            XCTAssertNil(old.replacingExceptions(.deny, peers: peers))
        }
        XCTAssertNil(TelegramPrivacyTests.setting([.contacts], kind: .phoneDiscovery).replacingExceptions(.deny, peers: [.user(7)]))
        XCTAssertNil(TelegramPrivacyTests.setting([.everybody, .contacts]).replacingExceptions(.deny, peers: [.user(7)]))
    }
    func testReplacementAdmissionRejectsSpecialRuleLossWrongKeyAndNoOp() throws {
        let old = TelegramPrivacyTests.setting()
        let replacement = try XCTUnwrap(old.replacingExceptions(.deny, peers: [.user(8)]))
        XCTAssertNotNil(TelegramPrivacyChange(expected: old, replacement: replacement).replacement)
        XCTAssertNil(TelegramPrivacyChange(expected: old, replacement: old).replacement)
        XCTAssertNil(TelegramPrivacyChange(expected: old, replacement: .init(kind: .presence, rules: [.contacts])).replacement)
        XCTAssertNil(TelegramPrivacyChange(expected: old, replacement: .init(kind: .voiceCalls, rules: replacement.rules)).replacement)
    }
}

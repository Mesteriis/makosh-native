import XCTest
import TelegramApi
@testable import MakoshTelegram

final class TelegramPrivacyTests: XCTestCase {
    static func setting(_ rules: [TelegramPrivacyRule] = [.allowUsers([7]), .denyChats([9]), .contacts, .premium], kind: TelegramPrivacyKind = .presence) -> TelegramPrivacySetting {
        .init(kind: kind, rules: rules)
    }
    func testNativeRulesPreserveEveryExceptionAndOrder() throws {
        let rules: [Api.PrivacyRule] = [.privacyValueAllowUsers(users: [7]), .privacyValueDisallowUsers(users: [8]),
            .privacyValueAllowChatParticipants(chats: [9]), .privacyValueDisallowChatParticipants(chats: [10]),
            .privacyValueAllowCloseFriends, .privacyValueAllowPremium, .privacyValueAllowBots, .privacyValueDisallowBots,
            .privacyValueDisallowContacts, .privacyValueAllowContacts, .privacyValueDisallowAll]
        let value = try XCTUnwrap(telegramPrivacySetting(.privacyRules(rules: rules, chats: [], users: []), kind: .presence))
        XCTAssertEqual(value.rules, [.allowUsers([7]), .denyUsers([8]), .allowChats([9]), .denyChats([10]),
            .closeFriends, .premium, .bots, .denyBots, .denyContacts, .contacts, .nobody])
        XCTAssertEqual(value.audience, .contacts)
    }
    func testChangingAudiencePreservesExceptionsWithoutReorderingOrDroppingSpecialRules() throws {
        let old = Self.setting([.allowUsers([7]), .denyChats([9]), .contacts, .nobody, .premium, .denyBots])
        let result = try XCTUnwrap(old.replacingAudience(.everybody))
        XCTAssertEqual(result.rules, [.allowUsers([7]), .denyChats([9]), .everybody, .premium, .denyBots])
        XCTAssertEqual(result.audience, .everybody)
        XCTAssertNil(old.replacingAudience(.contacts))
    }
    func testNonstandardOrMalformedRulesAreNeverRewritten() {
        for rules: [TelegramPrivacyRule] in [[], [.everybody, .contacts], [.contacts, .contacts], [.everybody, .nobody], [.denyContacts]] {
            XCTAssertNil(Self.setting(rules).audience)
            XCTAssertNil(Self.setting(rules).replacingAudience(.nobody))
        }
        for rules: [TelegramPrivacyRule] in [[.everybody, .allowUsers([0])], [.contacts, .denyChats([-1])], [.nobody, .allowUsers([1,1])], Array(repeating: .premium, count: 65)] {
            XCTAssertFalse(Self.setting(rules).isValid)
        }
        XCTAssertNil(Self.setting([.contacts], kind: .phoneDiscovery).replacingAudience(.nobody))
        XCTAssertNil(Self.setting([.nobody], kind: .phoneDiscovery).audience)
    }
    func testFreshBasisAndAccountMustMatchBeforePrivacyWrite() {
        let old = Self.setting()
        let change = TelegramPrivacyChange(expected: old, audience: .nobody)
        XCTAssertTrue(telegramAdmitPrivacyChange(accountID: 1, expectedAccountID: 1, current: old, change: change))
        XCTAssertFalse(telegramAdmitPrivacyChange(accountID: 2, expectedAccountID: 1, current: old, change: change))
        XCTAssertFalse(telegramAdmitPrivacyChange(accountID: 1, expectedAccountID: 1, current: Self.setting([.contacts]), change: change))
        XCTAssertFalse(telegramAdmitPrivacyChange(accountID: 1, expectedAccountID: 1, current: Self.setting(kind: .phoneNumber), change: change))
    }
    func testNativeInputRulesRequireEveryUserAndPreserveChatAndSpecialRules() throws {
        let value = Self.setting([.allowUsers([7]), .denyUsers([8]), .allowChats([9]), .denyChats([10]), .contacts, .premium, .denyBots])
        XCTAssertNil(telegramPrivacyInputRules(value, userHashes: [7: 70], selfID: 1))
        let inputs = try XCTUnwrap(telegramPrivacyInputRules(value, userHashes: [7: 70, 8: 80], selfID: 1))
        XCTAssertEqual(inputs.map { $0.descriptionFields().0 }, ["inputPrivacyValueAllowUsers", "inputPrivacyValueDisallowUsers", "inputPrivacyValueAllowChatParticipants", "inputPrivacyValueDisallowChatParticipants", "inputPrivacyValueAllowContacts", "inputPrivacyValueAllowPremium", "inputPrivacyValueDisallowBots"])
        guard case let .inputPrivacyValueAllowUsers(users) = inputs[0], case let .inputUser(id, hash) = users[0] else { return XCTFail("Missing native user identity") }
        XCTAssertEqual(id, 7); XCTAssertEqual(hash, 70)
    }
    func testPrivacyKeysKeepPhoneDiscoveryAndP2PSeparateFromVisibilityAndCalls() {
        let kinds: [(TelegramPrivacyKind, String)] = [(.presence,"inputPrivacyKeyStatusTimestamp"),(.phoneNumber,"inputPrivacyKeyPhoneNumber"),
            (.phoneDiscovery,"inputPrivacyKeyAddedByPhone"),(.voiceCalls,"inputPrivacyKeyPhoneCall"),(.callP2P,"inputPrivacyKeyPhoneP2P"),
            (.profilePhoto,"inputPrivacyKeyProfilePhoto"),(.groupInvitations,"inputPrivacyKeyChatInvite"),(.forwards,"inputPrivacyKeyForwards"),(.bio,"inputPrivacyKeyAbout"),(.birthday,"inputPrivacyKeyBirthday")]
        for (kind, key) in kinds { XCTAssertEqual(telegramPrivacyKey(kind).descriptionFields().0, key) }
    }
}

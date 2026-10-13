import XCTest
import TelegramApi
@testable import MakoshTelegram

final class TelegramExtendedPrivacyTests: XCTestCase {
    func testExtendedKindsResolveToDistinctNativePrivacyKeys() {
        for (name, key) in [("voiceMessages", "inputPrivacyKeyVoiceMessages"), ("giftsAutoSave", "inputPrivacyKeyStarGiftsAutoSave"), ("noPaidMessages", "inputPrivacyKeyNoPaidMessages")] {
            let kind = TelegramPrivacyKind(rawValue: name)
            XCTAssertNotNil(kind, "Missing privacy category \(name)")
            if let kind { XCTAssertEqual(telegramPrivacyKey(kind).descriptionFields().0, key) }
        }
    }
    func testGroupPremiumExceptionCanChangeWithoutDroppingOtherRules() {
        let old = TelegramPrivacySetting(kind: .groupInvitations, rules: [.allowUsers([7]), .contacts, .nobody, .denyBots])
        let wanted = TelegramPrivacySetting(kind: .groupInvitations, rules: [.allowUsers([7]), .premium, .contacts, .nobody, .denyBots])
        XCTAssertEqual(TelegramPrivacyChange(expected: old, replacement: wanted).replacement, wanted)
        XCTAssertEqual(TelegramPrivacyChange(expected: wanted, replacement: old).replacement, old)
    }
    func testOnlyReferenceSupportedSpecialExceptionChangesAreAdmitted() {
        let old = TelegramPrivacySetting(kind: .presence, rules: [.contacts, .closeFriends, .premium, .denyBots])
        XCTAssertNil(TelegramPrivacyChange(expected: old, replacement: .init(kind: .presence, rules: [.contacts, .closeFriends, .denyBots])).replacement)
        let groups = TelegramPrivacySetting(kind: .groupInvitations, rules: [.contacts, .premium, .denyBots])
        XCTAssertNil(TelegramPrivacyChange(expected: groups, replacement: .init(kind: .groupInvitations, rules: [.contacts, .premium])).replacement)
        XCTAssertNil(TelegramPrivacyChange(expected: groups, replacement: .init(kind: .groupInvitations, rules: [.premium, .premium, .contacts, .denyBots])).replacement)
    }
    func testSpecialExceptionBuilderInsertsBeforeBaseAndPreservesEveryOtherRule() throws {
        let old = TelegramPrivacySetting(kind: .groupInvitations, rules: [.allowUsers([7]), .contacts, .nobody, .denyBots])
        let enabled = try XCTUnwrap(old.replacingSpecialException(.premium, enabled: true))
        XCTAssertEqual(enabled.rules, [.allowUsers([7]), .premium, .contacts, .nobody, .denyBots])
        XCTAssertEqual(enabled.replacingSpecialException(.premium, enabled: false), old)
        XCTAssertNil(old.replacingSpecialException(.bots, enabled: true))
        let gift = TelegramPrivacySetting(kind: .giftsAutoSave, rules: [.closeFriends, .contacts])
        XCTAssertEqual(gift.replacingSpecialException(.bots, enabled: true)?.rules, [.closeFriends, .bots, .contacts])
    }
}

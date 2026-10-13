import XCTest
import TelegramApi
@testable import MakoshTelegram

final class TelegramGlobalPrivacyTests: XCTestCase {
    static let premium = TelegramPrivacyCapabilities(isPremium: true, nonPremiumMessageRestrictionAvailable: false, paidMessagesAvailable: true, maximumPaidStars: 10000)
    static let basic = TelegramPrivacyCapabilities(isPremium: false, nonPremiumMessageRestrictionAvailable: false, paidMessagesAvailable: true, maximumPaidStars: 10000)
    static let initial = TelegramGlobalPrivacySetting(flags: (1 << 0) | (1 << 1) | (1 << 6) | (1 << 7) | (1 << 29), paidStars: nil, giftFlags: (1 << 1) | (1 << 12))
    func testNativeRoundTripRetainsArchiveGiftAndUnknownFlags() throws {
        let native = Api.GlobalPrivacySettings.globalPrivacySettings(flags: Self.initial.flags, noncontactPeersPaidStars: nil,
            disallowedGifts: .disallowedGiftsSettings(flags: (1 << 1) | (1 << 12)))
        let value = try XCTUnwrap(TelegramGlobalPrivacySetting(native))
        XCTAssertEqual(value, Self.initial)
        let encoded = try XCTUnwrap(value.api)
        guard case let .globalPrivacySettings(flags, stars, gifts) = encoded, case let .disallowedGiftsSettings(giftFlags) = gifts else { return XCTFail("Missing preserved native fields") }
        XCTAssertEqual(flags, Self.initial.flags); XCTAssertNil(stars); XCTAssertEqual(giftFlags, (1 << 1) | (1 << 12))
        XCTAssertNil(TelegramGlobalPrivacySetting(.globalPrivacySettings(flags: 1 << 5, noncontactPeersPaidStars: nil, disallowedGifts: nil)))
        XCTAssertNil(TelegramGlobalPrivacySetting(.globalPrivacySettings(flags: 1 << 6, noncontactPeersPaidStars: nil, disallowedGifts: nil)))
        XCTAssertNil(TelegramGlobalPrivacySetting(.globalPrivacySettings(flags: 1 << 5, noncontactPeersPaidStars: -1, disallowedGifts: nil)))
    }
    func testReadTimeEditPreservesExistingFeeBeyondCurrentAccountLimit() throws {
        let old = TelegramGlobalPrivacySetting(flags: Self.initial.flags | (1 << 5), paidStars: 90000, giftFlags: Self.initial.giftFlags)
        let next = try XCTUnwrap(old.replacing(.hideReadTime(true)))
        XCTAssertEqual(next.flags, old.flags | (1 << 3)); XCTAssertEqual(next.paidStars, 90000); XCTAssertEqual(next.giftFlags, old.giftFlags)
        XCTAssertEqual(TelegramGlobalPrivacyChange(expected: old, proposed: next).replacement(capabilities: Self.basic), next)
    }
    func testIncomingMessageAndGiftEditsRequireCurrentCapabilities() throws {
        let restricted = try XCTUnwrap(Self.initial.replacing(.messagePolicy(.contactsAndPremium)))
        XCTAssertNil(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: restricted).replacement(capabilities: Self.basic))
        XCTAssertEqual(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: restricted).replacement(capabilities: Self.premium), restricted)
        let paid = try XCTUnwrap(Self.initial.replacing(.messagePolicy(.paidStars(25))))
        XCTAssertNil(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: paid).replacement(capabilities: Self.basic))
        XCTAssertEqual(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: paid).replacement(capabilities: Self.premium)?.paidStars, 25)
        let tooHigh = try XCTUnwrap(Self.initial.replacing(.messagePolicy(.paidStars(10001))))
        XCTAssertNil(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: tooHigh).replacement(capabilities: Self.premium))
        let gift = try XCTUnwrap(Self.initial.replacing(.allowGift(.unique, false)))
        XCTAssertEqual(gift.giftFlags, (1 << 1) | (1 << 2) | (1 << 12))
        XCTAssertNil(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: gift).replacement(capabilities: Self.basic))
        XCTAssertEqual(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: gift).replacement(capabilities: Self.premium), gift)
    }
    func testFreshConfigurationCanPermitNonPremiumRestrictionAndFeeRemovalIsAlwaysAvailable() throws {
        let capability = TelegramPrivacyCapabilities(isPremium: false, nonPremiumMessageRestrictionAvailable: true, paidMessagesAvailable: true, maximumPaidStars: 50)
        let paid = try XCTUnwrap(Self.initial.replacing(.messagePolicy(.paidStars(50))))
        XCTAssertNotNil(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: paid).replacement(capabilities: capability))
        let everyone = try XCTUnwrap(paid.replacing(.messagePolicy(.everybody)))
        XCTAssertEqual(everyone.paidStars, 0); XCTAssertEqual(everyone.flags & ((1 << 4) | (1 << 5)), 1 << 5)
        XCTAssertNotNil(TelegramGlobalPrivacyChange(expected: paid, proposed: everyone).replacement(capabilities: Self.basic))
    }
    func testGlobalChangesCannotRewriteUntouchedArchiveOrUnknownGiftFlags() throws {
        for flag in [Int32(1 << 0), 1 << 1, 1 << 2, 1 << 7, 1 << 29] {
            let tampered = TelegramGlobalPrivacySetting(flags: Self.initial.flags ^ flag, paidStars: nil, giftFlags: Self.initial.giftFlags)
            XCTAssertNil(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: tampered).replacement(capabilities: Self.premium))
        }
        let stripped = TelegramGlobalPrivacySetting(flags: Self.initial.flags, paidStars: nil, giftFlags: 1 << 1)
        XCTAssertNil(TelegramGlobalPrivacyChange(expected: Self.initial, proposed: stripped).replacement(capabilities: Self.premium))
        XCTAssertNil(Self.initial.replacing(.messagePolicy(.paidStars(0))))
        XCTAssertNil(Self.initial.replacing(.messagePolicy(.paidStars(-1))))
    }
}

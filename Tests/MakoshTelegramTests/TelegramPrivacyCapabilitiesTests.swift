import XCTest
import Foundation
@testable import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func seededPrivacyCapabilities(_ box: Postbox, premium: Bool, maximum: TelegramCore.JSON, override: Bool) -> Signal<TelegramPrivacyCapabilities?, NoError> {
    box.transaction { transaction in
        let id = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(1))
        let user = TelegramUser(id: id, accessHash: .personal(70), firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
            photo: [], botInfo: nil, restrictionInfo: nil, flags: premium ? [.isPremium] : [], emojiStatus: nil, usernames: [],
            storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([user], update: { _, new in new })
        let config = AppConfiguration(data: .dictionary(["stars_paid_messages_available": .bool(true),
            "new_noncontact_peers_require_premium_without_ownpremium": .bool(override), "stars_paid_message_amount_max": maximum]), hash: 1)
        transaction.setPreferencesEntry(key: PreferencesKeys.appConfiguration, value: PreferencesEntry(config))
        return telegramPrivacyCapabilities(transaction: transaction, peerID: id)
    }
}
private nonisolated func resolveVoicePrivacy(_ box: Postbox) -> Signal<[Int64: Int64]?, NoError> {
    box.transaction { transaction in
        telegramPrivacyResolveAdditions(transaction: transaction,
            current: .init(kind: .voiceMessages, rules: [.contacts]), sent: .init(kind: .voiceMessages, rules: [.nobody]), freshHashes: [:], selfID: 1)
    }
}
@MainActor final class TelegramPrivacyCapabilitiesTests: XCTestCase {
    func testVoiceWriteAdmissionRejectsMissingOrRevokedPremiumInFreshTransaction() async throws {
        let box = try await telegramDataPostbox(test: self)
        let missing = try await telegramDataValue(resolveVoicePrivacy(box), test: self); XCTAssertNil(missing)
        _ = try await telegramDataValue(seededPrivacyCapabilities(box, premium: true, maximum: .number(50), override: false), test: self)
        let allowed = try await telegramDataValue(resolveVoicePrivacy(box), test: self); XCTAssertEqual(allowed, [:])
        _ = try await telegramDataValue(seededPrivacyCapabilities(box, premium: false, maximum: .number(50), override: false), test: self)
        let revoked = try await telegramDataValue(resolveVoicePrivacy(box), test: self); XCTAssertNil(revoked)
    }
    func testCapabilitiesComeFromFreshEncryptedPostboxAndAccountConfiguration() async throws {
        let box = try await telegramDataPostbox(test: self)
        let premiumValue = try await telegramDataValue(seededPrivacyCapabilities(box, premium: true, maximum: .number(50), override: false), test: self)
        let premium = try XCTUnwrap(premiumValue)
        XCTAssertTrue(premium.isPremium); XCTAssertTrue(premium.canRestrictIncomingMessages); XCTAssertTrue(premium.paidMessagesAvailable); XCTAssertEqual(premium.maximumPaidStars, 50)
        let revokedValue = try await telegramDataValue(seededPrivacyCapabilities(box, premium: false, maximum: .number(50), override: false), test: self)
        let revoked = try XCTUnwrap(revokedValue)
        XCTAssertFalse(revoked.isPremium); XCTAssertFalse(revoked.canRestrictIncomingMessages)
        let enabledValue = try await telegramDataValue(seededPrivacyCapabilities(box, premium: false, maximum: .number(1), override: true), test: self)
        let enabled = try XCTUnwrap(enabledValue)
        XCTAssertTrue(enabled.canRestrictIncomingMessages); XCTAssertEqual(enabled.maximumPaidStars, 1)
    }
    func testMalformedFeeLimitDoesNotGrantPaidMessageCapability() async throws {
        let box = try await telegramDataPostbox(test: self)
        for maximum: TelegramCore.JSON in [.number(0), .number(-1), .number(1.5), .number(2147483648), .string("50"), .bool(true)] {
            let result = try await telegramDataValue(seededPrivacyCapabilities(box, premium: true, maximum: maximum, override: false), test: self)
            let value = try XCTUnwrap(result)
            XCTAssertTrue(value.isPremium); XCTAssertFalse(value.paidMessagesAvailable); XCTAssertEqual(value.maximumPaidStars, 0)
        }
    }
}

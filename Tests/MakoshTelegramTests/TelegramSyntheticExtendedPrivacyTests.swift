import XCTest
import Foundation
@testable import MakoshTelegram

@MainActor final class TelegramSyntheticExtendedPrivacyTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "MakoshPrivacySynthetic-" + UUID().uuidString
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }
    func testSyntheticWorkspaceAppliesGlobalAndGiftDraftsWithoutOpeningAnAccount() throws {
        let model = TelegramModel.syntheticPreview(dataDefaults: try defaults()), c = model.accountPrivacy
        c.open(); let snapshot = try XCTUnwrap(c.snapshot), global = try XCTUnwrap(snapshot.global)
        XCTAssertTrue(snapshot.capabilities?.isPremium == true); XCTAssertTrue(model.isSyntheticPreview)
        let paid = try XCTUnwrap(global.replacing(.messagePolicy(.paidStars(25))))
        XCTAssertTrue(c.applyGlobal(.init(expected: global, proposed: paid), contextID: c.contextID))
        XCTAssertEqual(c.snapshot?.global?.messagePolicy, .paidStars(25))
        let gifts = try XCTUnwrap(c.snapshot?.settings[.giftsAutoSave]), allowed = try XCTUnwrap(gifts.replacingSpecialException(.bots, enabled: true))
        XCTAssertTrue(c.apply(.init(expected: gifts, replacement: allowed), contextID: c.contextID))
        XCTAssertEqual(c.snapshot?.settings[.giftsAutoSave]?.rules, [.bots, .contacts])
        XCTAssertEqual(c.snapshot?.global?.messagePolicy, .paidStars(25))
    }
    func testBasicSyntheticWorkspaceAllowsReadTimeButRejectsPremiumVoiceAndIncomingRestriction() throws {
        let model = TelegramModel.syntheticPreview(dataDefaults: try defaults(), privacyPremium: false), c = model.accountPrivacy
        c.open(); let snapshot = try XCTUnwrap(c.snapshot), global = try XCTUnwrap(snapshot.global)
        XCTAssertFalse(c.canEdit(.voiceMessages)); XCTAssertFalse(snapshot.capabilities?.isPremium == true)
        let restricted = try XCTUnwrap(global.replacing(.messagePolicy(.contactsAndPremium)))
        XCTAssertFalse(c.applyGlobal(.init(expected: global, proposed: restricted), contextID: c.contextID))
        let hidden = try XCTUnwrap(global.replacing(.hideReadTime(true)))
        XCTAssertTrue(c.applyGlobal(.init(expected: global, proposed: hidden), contextID: c.contextID)); XCTAssertEqual(c.snapshot?.global?.hideReadTime, true)
    }
}

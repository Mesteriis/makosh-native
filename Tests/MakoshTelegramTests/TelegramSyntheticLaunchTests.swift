import XCTest
@testable import MakoshTelegram

final class TelegramSyntheticLaunchTests: XCTestCase {
    func testQABundleCannotFallBackToNormalAccountsAfterToolRelaunch() {
        XCTAssertFalse(telegramSyntheticLaunchAdmitted(arguments: ["Makosh"]))
        XCTAssertFalse(telegramSyntheticLaunchAdmitted(arguments: ["Makosh", "--telegram-group-synthetic-preview"]))
        XCTAssertFalse(telegramSyntheticLaunchAdmitted(arguments: ["Makosh", "--telegram-group-synthetic-preview", "--database-config", "--another-option"]))
        XCTAssertFalse(telegramSyntheticLaunchAdmitted(arguments: ["Makosh", "--telegram-group-synthetic-preview", "--database-config", "relative.json"]))
        XCTAssertFalse(telegramSyntheticLaunchAdmitted(arguments: ["Makosh", "--telegram-unknown-synthetic-preview", "--database-config", "/synthetic/db.json"]))
        XCTAssertTrue(telegramSyntheticLaunchAdmitted(arguments: ["Makosh", "--telegram-group-synthetic-preview", "--database-config", "/synthetic/db.json"]))
    }
    func testAmbiguousSyntheticModeOrDuplicateDatabaseConfigurationFailsClosed() {
        XCTAssertFalse(telegramSyntheticLaunchAdmitted(arguments: ["Makosh", "--telegram-group-synthetic-preview", "--telegram-avatar-synthetic-preview", "--database-config", "/synthetic/db.json"]))
        XCTAssertFalse(telegramSyntheticLaunchAdmitted(arguments: ["Makosh", "--telegram-group-synthetic-preview", "--database-config", "/synthetic/db.json", "--database-config", "/synthetic/other.json"]))
    }
    func testNativeSecretFixtureRequiresExplicitDatabaseConfiguration() {
        XCTAssertFalse(telegramSyntheticLaunchAdmitted(arguments: ["Makosh", "--telegram-secret-chats-synthetic-preview"]))
        XCTAssertTrue(telegramSyntheticLaunchAdmitted(arguments: ["Makosh", "--telegram-secret-chats-synthetic-preview", "--database-config", "/synthetic/db.json"]))
    }
}

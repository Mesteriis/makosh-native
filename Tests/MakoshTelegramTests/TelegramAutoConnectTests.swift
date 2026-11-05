import Foundation
import MakoshCore
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramAutoConnectTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "makosh.tests." + UUID().uuidString
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testNothingStartsWithoutARememberedConnection() throws {
        let model = TelegramModel(autoDownloadDefaults: try defaults())
        model.connectIfRemembered()
        XCTAssertEqual(model.phase, .configuration)
        XCTAssertNil(model.error)
    }

    func testRememberedConnectionStartsAndStopForgetsIt() throws {
        let defaults = try defaults()
        MakoshAutoConnect(scope: "telegram", defaults: defaults).remember("telegram", account: "session")
        let model = TelegramModel(autoDownloadDefaults: defaults)
        model.connectIfRemembered()
        // A source build without the API pair reports it; a configured one starts connecting.
        XCTAssertTrue(model.phase != .configuration || model.error != nil)
        model.stopConnection()
        XCTAssertTrue(MakoshAutoConnect(scope: "telegram", defaults: defaults).remembered("telegram").isEmpty)
        XCTAssertEqual(model.phase, .configuration)
    }
}

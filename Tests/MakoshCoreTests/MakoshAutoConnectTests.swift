import Foundation
import XCTest
@testable import MakoshCore

final class MakoshAutoConnectTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    override func setUp() {
        suite = "makosh.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testRememberedAccountsSurviveAndForgetIsExplicit() {
        let store = MakoshAutoConnect(scope: "makosh", defaults: defaults)
        XCTAssertTrue(store.remembered("mail").isEmpty)
        store.remember("mail", account: "a")
        store.remember("mail", account: "b")
        store.remember("whatsapp", account: "a")
        let reopened = MakoshAutoConnect(scope: "makosh", defaults: defaults)
        XCTAssertEqual(reopened.remembered("mail"), ["a", "b"])
        reopened.forget("mail", account: "a")
        XCTAssertEqual(MakoshAutoConnect(scope: "makosh", defaults: defaults).remembered("mail"), ["b"])
        XCTAssertEqual(reopened.remembered("whatsapp"), ["a"])
    }

    func testScopesDoNotShareAccounts() {
        MakoshAutoConnect(scope: "makosh", defaults: defaults).remember("mail", account: "real")
        XCTAssertTrue(MakoshAutoConnect(scope: "qa_mail_x", defaults: defaults).remembered("mail").isEmpty)
    }
}

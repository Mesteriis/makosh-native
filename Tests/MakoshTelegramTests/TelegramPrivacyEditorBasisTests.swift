import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramPrivacyEditorBasisTests: XCTestCase {
    func testEditorCannotBorrowNewContextAfterRefreshWithIdenticalRules() throws {
        let c = TelegramModel.syntheticPreview().accountPrivacy; c.open()
        let basis = try XCTUnwrap(TelegramPrivacyEditorBasis(controller: c, kind: .presence))
        let replacement = try XCTUnwrap(basis.setting.replacingExceptions(.deny, peers: [.user(7)]))
        XCTAssertNotNil(basis.change(to: replacement, controller: c))
        c.refresh(); XCTAssertEqual(c.snapshot?.settings[.presence], basis.setting)
        XCTAssertNil(basis.change(to: replacement, controller: c))
    }
    func testRebindingIdenticalSyntheticAccountCannotReuseOpenEditor() throws {
        let c = TelegramModel.syntheticPreview().accountPrivacy; c.open()
        let basis = try XCTUnwrap(TelegramPrivacyEditorBasis(controller: c, kind: .presence))
        let replacement = try XCTUnwrap(basis.setting.replacingAudience(.nobody))
        c.bind(TelegramSyntheticPrivacyProvider()); c.open()
        XCTAssertEqual(c.snapshot?.settings[.presence], basis.setting)
        XCTAssertNil(basis.change(to: replacement, controller: c))
    }
}

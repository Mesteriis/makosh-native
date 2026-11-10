import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramWorkspaceProfileFixtureTests: XCTestCase {
    func testWorkspaceFixtureOpensEditableOwnProfileWithoutChangingChatAccount() throws {
        let model = TelegramModel.syntheticWorkspaceLayoutPreview()
        XCTAssertTrue(model.isSyntheticPreview)
        XCTAssertEqual(model.draftAccountID, -1)
        let accountID = try XCTUnwrap(model.avatarEditing.accountID)
        let target = TelegramAvatarTarget(accountID: accountID, peerID: accountID, kind: .main)
        model.avatarEditing.open(target)
        XCTAssertEqual(model.avatarEditing.status, .ready)
        XCTAssertEqual(model.avatarEditing.snapshot?.target, target)
        XCTAssertEqual(model.avatarEditing.snapshot?.canEdit, true)
        XCTAssertNotNil(model.avatarEditing.snapshot?.photoID)
    }
}

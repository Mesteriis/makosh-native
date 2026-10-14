import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramGroupMembershipModelTests: XCTestCase {
    func testOpeningMembershipRequiresCurrentProfileAndClosesOnChatChange() throws {
        let model = TelegramModel.syntheticGroupMembershipPreview()
        model.selectedChatID = 4_294_970_002; model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Synthetic group missing") }
        XCTAssertFalse(model.openGroupMembership(profile, contextID: UUID(), section: .activeLinks))
        XCTAssertTrue(model.openGroupMembership(profile, contextID: model.contactProfileContextID, section: .activeLinks))
        XCTAssertEqual(model.groupMembership.status, .ready)
        model.selectedChatID = 8_589_940_003
        XCTAssertNil(model.groupMembership.snapshot)
        XCTAssertFalse(model.openGroupMembership(profile, contextID: model.contactProfileContextID, section: .requests))
    }
    func testInvitingArbitraryOrStaleSearchResultIsRefused() {
        let model = TelegramModel.syntheticGroupMembershipPreview()
        model.selectedChatID = 4_294_970_002; model.loadContactProfile()
        guard let basis = model.groupMembership.snapshot else { return XCTFail("Synthetic group missing") }
        let arbitrary = TelegramDiscoveredPeer(chat: .init(id: 7, title: "Synthetic Alice", preview: "", unreadCount: 0), username: "alice")
        XCTAssertFalse(model.inviteGroupMember(arbitrary, searchContextID: model.groupMemberSearch.contextID,
            basis: basis, contextID: model.groupMembership.contextID))
    }
}

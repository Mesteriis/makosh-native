import XCTest
import TelegramApi
@testable import MakoshTelegram

final class TelegramGroupAdminPresentationTests: XCTestCase {
    func testTitleAndAboutChangesKeepExactBeforeAndAfterText() throws {
        let title = try XCTUnwrap(telegramGroupAdminPresentation(.channelAdminLogEventActionChangeTitle(prevValue: "Before", newValue: "After")))
        XCTAssertEqual(title.previous, "Before"); XCTAssertEqual(title.current, "After")
        let about = try XCTUnwrap(telegramGroupAdminPresentation(.channelAdminLogEventActionChangeAbout(prevValue: "Old description", newValue: "New description")))
        XCTAssertEqual(about.previous, "Old description"); XCTAssertEqual(about.current, "New description")
    }
    func testInviteAndRequestEventsHaveDistinctHumanReadableMeaning() throws {
        let joined = try XCTUnwrap(telegramGroupAdminPresentation(.channelAdminLogEventActionParticipantJoin))
        let left = try XCTUnwrap(telegramGroupAdminPresentation(.channelAdminLogEventActionParticipantLeave))
        XCTAssertNotEqual(joined.summary, left.summary)
        XCTAssertFalse(joined.summary.contains("channelAdminLogEventAction"))
        let enabled = try XCTUnwrap(telegramGroupAdminPresentation(.channelAdminLogEventActionToggleNoForwards(newValue: .boolTrue)))
        let disabled = try XCTUnwrap(telegramGroupAdminPresentation(.channelAdminLogEventActionToggleNoForwards(newValue: .boolFalse)))
        XCTAssertNotEqual(enabled.current, disabled.current)
    }
    func testInvalidTimerDoesNotInventAValidSetting() {
        XCTAssertNil(telegramGroupAdminPresentation(.channelAdminLogEventActionChangeHistoryTTL(prevValue: 0, newValue: -1)))
    }
    func testAdministratorChangeNamesExactSubjectAndRights() throws {
        let before = Api.ChannelParticipant.channelParticipant(flags: 0, userId: 7, date: 1, subscriptionUntilDate: nil)
        let after = Api.ChannelParticipant.channelParticipantAdmin(flags: 0, userId: 7, inviterId: nil, promotedBy: 101,
            date: 2, adminRights: .chatAdminRights(flags: 32), rank: "QA")
        let value = try XCTUnwrap(telegramGroupAdminPresentation(.channelAdminLogEventActionParticipantToggleAdmin(prevParticipant: before, newParticipant: after)))
        XCTAssertEqual(value.subjectIDs, [7])
        XCTAssertTrue(value.current?.contains("Приглашать участников") == true)
        XCTAssertTrue(value.current?.contains("QA") == true)
        XCTAssertEqual(value.previous, "Участник")
    }
    func testParticipantChangeCannotCombineDifferentSubjects() {
        XCTAssertNil(telegramGroupAdminPresentation(.channelAdminLogEventActionParticipantToggleBan(
            prevParticipant: .channelParticipant(flags: 0, userId: 7, date: 1, subscriptionUntilDate: nil),
            newParticipant: .channelParticipantLeft(peer: .peerUser(userId: 8)))))
    }
    func testInviteEditRetainsExactBeforeAndAfterLinks() throws {
        func invite(_ value: String) -> Api.ExportedChatInvite {
            .chatInviteExported(flags: 0, link: value, adminId: 101, date: 1000, startDate: nil, expireDate: nil, usageLimit: nil,
                usage: nil, requested: nil, subscriptionExpired: nil, title: nil, subscriptionPricing: nil)
        }
        let value = try XCTUnwrap(telegramGroupAdminPresentation(.channelAdminLogEventActionExportedInviteEdit(
            prevInvite: invite("https://t.me/+Before"), newInvite: invite("https://t.me/+After"))))
        XCTAssertTrue(value.previous?.contains("https://t.me/+Before") == true)
        XCTAssertTrue(value.current?.contains("https://t.me/+After") == true)
    }
}

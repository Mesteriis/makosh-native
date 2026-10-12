import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramSearchDateAndSendersTests: XCTestCase {
    func testCalendarUsesLocalMidnightAcrossBothDSTTransitions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        func day(_ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
        }
        let spring = try XCTUnwrap(telegramSearchDayTimestamp(day(3, 29), calendar: calendar))
        let afterSpring = try XCTUnwrap(telegramSearchDayTimestamp(day(3, 30), calendar: calendar))
        XCTAssertEqual(afterSpring - spring, 23 * 3600)
        let autumn = try XCTUnwrap(telegramSearchDayTimestamp(day(10, 25), calendar: calendar))
        let afterAutumn = try XCTUnwrap(telegramSearchDayTimestamp(day(10, 26), calendar: calendar))
        XCTAssertEqual(afterAutumn - autumn, 25 * 3600)
        XCTAssertEqual(Date(timeIntervalSince1970: Double(spring)), calendar.startOfDay(for: try day(3, 29)))
    }

    func testUnrepresentableCalendarDayFailsWithoutClamping() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for value in [Double.infinity, -.infinity, .nan, Double(Int32.max) + 86400, Double(Int32.min) - 86400] {
            XCTAssertNil(telegramSearchDayTimestamp(Date(timeIntervalSince1970: value), calendar: calendar))
        }
        XCTAssertEqual(telegramSearchDayTimestamp(Date(timeIntervalSince1970: 1234), calendar: calendar), 0)
    }

    #if DEBUG
    func testDateJumpRetainsQueryAndDraftAndStaysWithinSelectedTopic() async throws {
        let model = TelegramModel.syntheticExtendedMessagesPreview()
        model.forumTopics.setVisible(true)
        let topic = try XCTUnwrap(model.forumTopics.snapshot?.topics.first { $0.threadID == 7 })
        XCTAssertTrue(model.selectForumTopic(topic, contextID: model.messageActionContextID))
        model.draft = "Черновик темы"
        model.search.messageQuery = "Тестовое сообщение"
        for _ in 0..<150 where model.search.messageStatus != .ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.search.messageStatus, .ready)
        let result = try XCTUnwrap(model.search.messages.last)
        model.search.jumpToDate(result.date)
        XCTAssertEqual(model.search.dateStatus, .ready)
        XCTAssertEqual(model.selectedThreadID, 7)
        XCTAssertEqual(model.search.messageQuery, "Тестовое сообщение")
        XCTAssertEqual(model.draft, "Черновик темы")
        XCTAssertFalse(model.search.showsResults)
        XCTAssertFalse(model.messages.isEmpty)
        XCTAssertTrue(model.messages.allSatisfy { $0.actionMetadata?.threadID == 7 })
        model.search.selectChat(nil)
        model.search.jumpToDate(result.date)
        XCTAssertEqual(model.search.dateStatus, .failed)
    }

    func testSenderSuggestionsCancelOnQueryAndConversationChange() async throws {
        let senders = TelegramSearchSenders()
        senders.useSyntheticPreview(isGroup: true)
        senders.retry()
        senders.query = "собеседник"
        for _ in 0..<150 where senders.status != .ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(senders.candidates.map(\.id), [999])
        senders.query = "Макош"
        senders.useSyntheticPreview(isGroup: false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(senders.available)
        XCTAssertTrue(senders.candidates.isEmpty)
        XCTAssertEqual(senders.status, .idle)
        senders.retry()
        XCTAssertEqual(senders.status, .idle)
    }
    #endif
}

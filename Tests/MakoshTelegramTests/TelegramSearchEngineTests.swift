import XCTest
import TelegramApi
@testable import TelegramCore

final class TelegramSearchEngineTests: XCTestCase {
    private func state(completed: Bool, count: Int32, nextRate: Int32? = nil,
                       additional: SearchMessagesPeerState? = nil) -> SearchMessagesState {
        SearchMessagesState(main: SearchMessagesPeerState(messages: [], readStates: [:],
            threadInfo: [:], totalCount: count, completed: completed, nextRate: nextRate), additional: additional)
    }

    func testFirstFailureReturnsRetryableEmptyStateAndSuccessfulRetryIsNotFailure() throws {
        let failed = try XCTUnwrap(makoshSearchFailure(previous: nil, main: .failed, additional: .skipped))
        XCTAssertTrue(failed.0.searchFailed)
        XCTAssertFalse(failed.0.completed)
        XCTAssertTrue(failed.0.messages.isEmpty)
        XCTAssertFalse(failed.1.main.completed)
        XCTAssertNil(failed.1.main.nextRate)
        XCTAssertNil(makoshSearchFailure(previous: failed.1,
            main: .success(.messages(messages: [], chats: [], users: [])), additional: .skipped))
    }

    func testLaterFailureRetainsExactCursorAndCompletedAdditionalState() throws {
        let additional = SearchMessagesPeerState(messages: [], readStates: [:], threadInfo: [:],
            totalCount: 7, completed: true, nextRate: 45)
        let previous = state(completed: false, count: 30, nextRate: 123, additional: additional)
        let failed = try XCTUnwrap(makoshSearchFailure(previous: previous, main: .failed, additional: .skipped))
        XCTAssertEqual(failed.1, previous)
        XCTAssertEqual(failed.1.main.nextRate, 123)
        XCTAssertEqual(failed.1.additional?.nextRate, 45)
        XCTAssertEqual(failed.0.totalCount, 37)
        XCTAssertFalse(failed.0.completed)
    }

    func testEitherMigratedPeerFailureDiscardsPairAtomically() throws {
        let previous = state(completed: true, count: 9, nextRate: 7)
        let success = MakoshSearchRequestOutcome.success(.messages(messages: [], chats: [], users: []))
        for pair in [(success, MakoshSearchRequestOutcome.failed), (.failed, success), (.failed, .failed)] {
            let failed = try XCTUnwrap(makoshSearchFailure(previous: previous, main: pair.0, additional: pair.1))
            XCTAssertEqual(failed.1, previous)
            XCTAssertTrue(failed.0.searchFailed)
            XCTAssertFalse(failed.0.completed)
        }
    }

    func testSkippedCompletedDeferredAbsentAndSuccessfulEmptyAreNotFailures() {
        let previous = state(completed: true, count: 0)
        let success = MakoshSearchRequestOutcome.success(.messages(messages: [], chats: [], users: []))
        for pair in [(MakoshSearchRequestOutcome.skipped, .skipped), (success, .skipped), (.skipped, success), (success, success)] {
            XCTAssertNil(makoshSearchFailure(previous: previous, main: pair.0, additional: pair.1))
        }
        XCTAssertFalse(MakoshSearchRequestOutcome.skipped.isFailure)
        XCTAssertNil(MakoshSearchRequestOutcome.skipped.result)
        XCTAssertNotNil(success.result)
        XCTAssertNil(MakoshSearchRequestOutcome.failed.result)
    }

    func testResultEqualityIncludesFailureCompletionAndTotalCount() {
        func result(_ failed: Bool = false, _ completed: Bool = true, _ count: Int32 = 0) -> SearchMessagesResult {
            SearchMessagesResult(messages: [], readStates: [:], threadInfo: [:], totalCount: count,
                completed: completed, searchFailed: failed)
        }
        XCTAssertEqual(result(), result())
        XCTAssertNotEqual(result(), result(true))
        XCTAssertNotEqual(result(), result(false, false))
        XCTAssertNotEqual(result(), result(false, true, 1))
        XCTAssertFalse(result().searchFailed)
    }
}

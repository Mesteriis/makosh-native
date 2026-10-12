import XCTest
@testable import MakoshTelegram

final class TelegramSearchTrackerTests: XCTestCase {
    func testFailedPagePreservesSuccessfulCursorAndCompletionUntilRetrySucceeds() throws {
        var tracker = TelegramSearchTracker<String>()
        let first = tracker.begin()
        XCTAssertTrue(tracker.receive(requestID: first, state: "page-one", completed: false, failed: false))
        XCTAssertTrue(tracker.canLoadMore)
        let second = tracker.begin()
        XCTAssertEqual(tracker.state, "page-one")
        XCTAssertFalse(tracker.canLoadMore)
        XCTAssertFalse(tracker.canRetry)
        XCTAssertTrue(tracker.receive(requestID: second, state: "invalid-cursor", completed: true, failed: true))
        XCTAssertEqual(tracker.state, "page-one")
        XCTAssertFalse(tracker.completed)
        XCTAssertEqual(tracker.status, .failed)
        XCTAssertTrue(tracker.canRetry)
        XCTAssertFalse(tracker.canLoadMore)
        let retry = tracker.begin()
        XCTAssertTrue(tracker.receive(requestID: retry, state: "page-two", completed: true, failed: false))
        XCTAssertEqual(tracker.state, "page-two")
        XCTAssertTrue(tracker.completed)
        XCTAssertFalse(tracker.canLoadMore)
        XCTAssertFalse(tracker.canRetry)
        let refresh = tracker.begin()
        tracker.receive(requestID: refresh, state: "invalid-refresh", completed: false, failed: true)
        XCTAssertEqual(tracker.state, "page-two")
        XCTAssertTrue(tracker.completed)
    }

    func testFirstFailureDoesNotInstallCompletedEmptyState() {
        var tracker = TelegramSearchTracker<Int>()
        let request = tracker.begin()
        tracker.receive(requestID: request, state: 99, completed: true, failed: true)
        XCTAssertNil(tracker.state)
        XCTAssertFalse(tracker.completed)
        XCTAssertTrue(tracker.canRetry)
    }

    func testNewQueryResetClearsStateAndRejectsOldQueryResponse() {
        var tracker = TelegramSearchTracker<String>()
        let old = tracker.begin()
        tracker.receive(requestID: old, state: "old-query", completed: true, failed: false)
        tracker.reset()
        XCTAssertNil(tracker.requestID)
        XCTAssertNil(tracker.state)
        XCTAssertFalse(tracker.completed)
        XCTAssertEqual(tracker.status, .idle)
        XCTAssertFalse(tracker.canLoadMore)
        XCTAssertFalse(tracker.canRetry)
        XCTAssertFalse(tracker.receive(requestID: old, state: "late-old-query", completed: true, failed: false))
        XCTAssertFalse(tracker.timeout(requestID: old))
        let current = tracker.begin()
        XCTAssertFalse(tracker.receive(requestID: old, state: "still-old", completed: true, failed: false))
        XCTAssertTrue(tracker.receive(requestID: current, state: "new-query", completed: false, failed: false))
        XCTAssertEqual(tracker.state, "new-query")
    }

    func testSameQueryReplacementAlwaysHasNewTokenAndRejectsLateSuccessAndFailure() {
        var tracker = TelegramSearchTracker<Int>()
        let old = tracker.begin()
        let current = tracker.begin()
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(tracker.receive(requestID: old, state: 1, completed: true, failed: false))
        XCTAssertFalse(tracker.receive(requestID: old, state: 2, completed: false, failed: true))
        XCTAssertFalse(tracker.timeout(requestID: old))
        XCTAssertNil(tracker.state)
        XCTAssertEqual(tracker.status, .loading)
        XCTAssertEqual(tracker.requestID, current)
    }

    func testTimeoutAllowsLiveRecoveryUntilReplaced() {
        var tracker = TelegramSearchTracker<Int>()
        let request = tracker.begin()
        XCTAssertTrue(tracker.timeout(requestID: request))
        XCTAssertFalse(tracker.timeout(requestID: request))
        XCTAssertEqual(tracker.status, .timedOut)
        XCTAssertTrue(tracker.canRetry)
        XCTAssertTrue(tracker.receive(requestID: request, state: 42, completed: false, failed: false))
        XCTAssertEqual(tracker.status, .ready)
        XCTAssertTrue(tracker.canLoadMore)
        XCTAssertFalse(tracker.timeout(requestID: request))
        let pending = tracker.begin()
        XCTAssertTrue(tracker.timeout(requestID: pending))
        let replacement = tracker.begin()
        XCTAssertFalse(tracker.receive(requestID: pending, state: 99, completed: true, failed: false))
        XCTAssertEqual(tracker.state, 42)
        XCTAssertEqual(tracker.status, .loading)
        XCTAssertTrue(tracker.receive(requestID: replacement, state: 43, completed: true, failed: false))
    }

    func testNavigationFlagsBlockRepeatedLoadMoreAndRetryWhileLoading() {
        var tracker = TelegramSearchTracker<Void>()
        XCTAssertFalse(tracker.canLoadMore)
        XCTAssertFalse(tracker.canRetry)
        let request = tracker.begin()
        XCTAssertFalse(tracker.canLoadMore)
        XCTAssertFalse(tracker.canRetry)
        tracker.receive(requestID: request, state: (), completed: false, failed: false)
        XCTAssertTrue(tracker.canLoadMore)
        let next = tracker.begin()
        XCTAssertFalse(tracker.canLoadMore)
        tracker.receive(requestID: next, state: (), completed: false, failed: true)
        XCTAssertTrue(tracker.canRetry)
        _ = tracker.begin()
        XCTAssertFalse(tracker.canRetry)
        XCTAssertFalse(tracker.canLoadMore)
    }
}

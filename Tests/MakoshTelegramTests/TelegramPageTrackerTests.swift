import XCTest
@testable import MakoshTelegram

final class TelegramPageTrackerTests: XCTestCase {
    func testReplacedPageRejectsLateEmissionEvenAtSameAnchor() {
        var tracker = TelegramPageTracker<Int>()
        let old = tracker.begin(anchor: 20)
        let current = tracker.begin(anchor: 20)
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(tracker.update(requestID: old, previous: 1, next: 99, isLoading: false))
        XCTAssertEqual(tracker.status, .loading)
        XCTAssertNil(tracker.previousCursor)
        XCTAssertTrue(tracker.update(requestID: current, previous: 10, next: 30, isLoading: false))
        XCTAssertEqual(tracker.previousCursor, 10)
    }

    func testResetInvalidatesAccountWindowAndClearsBoundaries() {
        var tracker = TelegramPageTracker<Int>()
        let old = tracker.begin(anchor: 20)
        tracker.update(requestID: old, previous: 10, next: 30, isLoading: false, hasPreviousGap: true, hasNextGap: true)
        tracker.reset()
        XCTAssertNil(tracker.requestID)
        XCTAssertNil(tracker.anchor)
        XCTAssertNil(tracker.previousCursor)
        XCTAssertNil(tracker.nextCursor)
        XCTAssertFalse(tracker.hasPreviousGap)
        XCTAssertFalse(tracker.hasNextGap)
        XCTAssertEqual(tracker.status, .idle)
        XCTAssertTrue(tracker.isAtLatest)
        XCTAssertFalse(tracker.update(requestID: old, previous: 1, next: 2, isLoading: false))
        XCTAssertFalse(tracker.timeout(requestID: old))
    }

    func testNavigationRejectsAnchorDuplicatesAndBlocksRepeatedClicksWhileLoading() {
        var tracker = TelegramPageTracker<Int>()
        let token = tracker.begin(anchor: 20)
        tracker.update(requestID: token, previous: 20, next: 30, isLoading: false)
        XCTAssertFalse(tracker.canLoadPrevious)
        XCTAssertTrue(tracker.canLoadNext)
        XCTAssertFalse(tracker.isAtLatest)
        let next = tracker.begin(anchor: tracker.nextCursor)
        XCTAssertFalse(tracker.canLoadNext)
        XCTAssertFalse(tracker.canLoadPrevious)
        XCTAssertNil(tracker.nextCursor)
        tracker.update(requestID: next, previous: 20, next: 30, isLoading: false)
        XCTAssertTrue(tracker.canLoadPrevious)
        XCTAssertFalse(tracker.canLoadNext)
    }

    func testEmptyAndPartialHoleEmissionsPreserveLoadingAndGapInformation() {
        var tracker = TelegramPageTracker<Int>()
        let token = tracker.begin(anchor: nil)
        tracker.update(requestID: token, previous: nil, next: nil, isLoading: true, hasPreviousGap: true)
        XCTAssertTrue(tracker.isAtLatest)
        XCTAssertTrue(tracker.hasPreviousGap)
        XCTAssertFalse(tracker.canLoadPrevious)
        tracker.update(requestID: token, previous: 10, next: nil, isLoading: true, hasPreviousGap: true)
        XCTAssertEqual(tracker.previousCursor, 10)
        XCTAssertFalse(tracker.canLoadPrevious)
        tracker.update(requestID: token, previous: 10, next: nil, isLoading: false)
        XCTAssertTrue(tracker.canLoadPrevious)
        XCTAssertFalse(tracker.hasPreviousGap)
        tracker.update(requestID: token, previous: nil, next: nil, isLoading: false)
        XCTAssertFalse(tracker.canLoadPrevious)
        XCTAssertEqual(tracker.status, .ready)
    }

    func testTimeoutRejectsStaleTokensAndRecoversOnlyOnStableEmission() {
        var tracker = TelegramPageTracker<Int>()
        let stale = tracker.begin(anchor: nil)
        let current = tracker.begin(anchor: 20)
        XCTAssertFalse(tracker.timeout(requestID: stale))
        tracker.update(requestID: current, previous: 10, next: 30, isLoading: true, hasPreviousGap: true)
        XCTAssertTrue(tracker.timeout(requestID: current))
        XCTAssertTrue(tracker.canLoadPrevious)
        XCTAssertTrue(tracker.canLoadNext)
        XCTAssertFalse(tracker.timeout(requestID: current))
        tracker.update(requestID: current, previous: 9, next: 31, isLoading: true, hasPreviousGap: true)
        XCTAssertEqual(tracker.status, .timedOut)
        XCTAssertEqual(tracker.previousCursor, 9)
        tracker.update(requestID: current, previous: 8, next: 32, isLoading: false)
        XCTAssertEqual(tracker.status, .ready)
        XCTAssertFalse(tracker.timeout(requestID: current))
        let retry = tracker.begin(anchor: tracker.anchor)
        XCTAssertEqual(tracker.anchor, 20)
        XCTAssertEqual(tracker.status, .loading)
        XCTAssertNotEqual(retry, current)
    }

    func testRootArchiveAndHistoryWindowsAreIndependent() {
        var root = TelegramPageTracker<Int>()
        var archive = TelegramPageTracker<Int>()
        var history = TelegramPageTracker<String>()
        let rootToken = root.begin(anchor: nil)
        let archiveToken = archive.begin(anchor: 100)
        let historyToken = history.begin(anchor: "message")
        XCTAssertFalse(archive.update(requestID: rootToken, previous: 1, next: 2, isLoading: false))
        root.update(requestID: rootToken, previous: 5, next: nil, isLoading: false)
        archive.timeout(requestID: archiveToken)
        history.update(requestID: historyToken, previous: "older", next: "newer", isLoading: false)
        XCTAssertEqual(root.status, .ready)
        XCTAssertEqual(archive.status, .timedOut)
        XCTAssertEqual(history.status, .ready)
        archive.reset()
        XCTAssertEqual(root.previousCursor, 5)
        XCTAssertEqual(history.previousCursor, "older")
    }
}

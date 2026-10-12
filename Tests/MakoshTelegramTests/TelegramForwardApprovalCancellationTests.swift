import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramForwardApprovalCancellationTests: XCTestCase {
    func testForwardCancellationFromApprovalEventCannotStartNativeBegin() {
        let lease = ForwardLease()
        var events = 0, begins = 0
        lease.continueAfterApproval(notify: { events += 1; lease.cancel() }, begin: { begins += 1 })
        XCTAssertEqual(events, 1); XCTAssertTrue(lease.stopped)
        XCTAssertEqual(begins, 0, "Cancellation in approvalCompleted is still before durable Begin")
    }
    func testSavedCancellationFromCommittingEventCannotStartNativeBegin() {
        let lease = SavedForwardLease()
        var events = 0, begins = 0
        lease.continueAfterApproval(notify: { events += 1; lease.cancel() }, begin: { begins += 1 })
        XCTAssertEqual(events, 1); XCTAssertTrue(lease.stopped)
        XCTAssertEqual(begins, 0, "A synchronous account/context rebind in committing must stop pre-Begin work")
    }
    func testLiveApprovalPublishesBeforeNativeBeginExactlyOnce() {
        let forward = ForwardLease(), saved = SavedForwardLease()
        var events: [String] = []
        forward.continueAfterApproval(notify: { events.append("forward-event") }, begin: { events.append("forward-begin") })
        saved.continueAfterApproval(notify: { events.append("saved-event") }, begin: { events.append("saved-begin") })
        XCTAssertEqual(events, ["forward-event", "forward-begin", "saved-event", "saved-begin"])
    }
    func testAlreadyCancelledApprovalPublishesAndBeginsNothing() {
        let forward = ForwardLease(), saved = SavedForwardLease()
        forward.cancel(); saved.cancel()
        var callbacks = 0
        forward.continueAfterApproval(notify: { callbacks += 1 }, begin: { callbacks += 1 })
        saved.continueAfterApproval(notify: { callbacks += 1 }, begin: { callbacks += 1 })
        XCTAssertEqual(callbacks, 0)
    }
}

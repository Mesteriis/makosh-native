import XCTest
@testable import MakoshTelegram

final class TelegramCodeHighlightQueueTests: XCTestCase {
    func testAdmissionBoundsRetainedJobsUntilTheyAreReleased() {
        let worker = TelegramCodeHighlightQueue()
        for _ in 0..<4 { XCTAssertTrue(worker.admit()) }
        XCTAssertFalse(worker.admit())
        worker.release()
        XCTAssertTrue(worker.admit())
        XCTAssertFalse(worker.admit())
        for _ in 0..<4 { worker.release() }
        for _ in 0..<4 { XCTAssertTrue(worker.admit()) }
        XCTAssertFalse(worker.admit())
    }
}

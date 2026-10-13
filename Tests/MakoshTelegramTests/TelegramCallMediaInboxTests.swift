import XCTest
import CoreVideo
@testable import MakoshTelegram

final class TelegramCallMediaInboxTests: XCTestCase {
    func testFramesCoalesceToLatestAndScheduleOnlyOneDrain() throws {
        let scheduler = MediaInboxScheduler(), output = MediaInboxOutput()
        let inbox = TelegramCallMediaInbox(schedule: scheduler.schedule, deliver: output.append)
        let first = try frame(width: 2), last = try frame(width: 4)
        for _ in 0..<100 { XCTAssertTrue(inbox.enqueue(.frame(first))) }
        XCTAssertTrue(inbox.enqueue(.frame(last)))
        XCTAssertEqual(scheduler.count, 1); XCTAssertEqual(output.count, 0)
        scheduler.drain()
        XCTAssertEqual(output.count, 1)
        guard case let .frame(value) = output.values[0] else { return XCTFail("Missing actual last frame") }
        XCTAssertEqual(CVPixelBufferGetWidth(value), 4)
    }
    func testSignalingBudgetFailsClosedInsteadOfGrowingQueue() {
        let scheduler = MediaInboxScheduler(), output = MediaInboxOutput()
        let inbox = TelegramCallMediaInbox(schedule: scheduler.schedule, deliver: output.append)
        for _ in 0..<16 { XCTAssertTrue(inbox.enqueue(.signaling(Data(count: 65536)))) }
        XCTAssertFalse(inbox.enqueue(.signaling(Data([1])))); XCTAssertFalse(inbox.enqueue(.state(2)))
        scheduler.drain()
        XCTAssertEqual(output.count, 1)
        guard case .failed = output.values[0] else { return XCTFail("Overflow must fail the call") }
    }
    func testRevocationDropsPendingEventsButReleaseIsDeliveredExactlyOnce() throws {
        let scheduler = MediaInboxScheduler(), output = MediaInboxOutput()
        let inbox = TelegramCallMediaInbox(schedule: scheduler.schedule, deliver: output.append)
        XCTAssertTrue(inbox.enqueue(.state(2))); XCTAssertTrue(inbox.enqueue(.frame(try frame(width: 2))))
        inbox.revoke(); XCTAssertFalse(inbox.enqueue(.signaling(Data([1]))))
        inbox.release(); inbox.release(); scheduler.drain()
        XCTAssertEqual(output.count, 1)
        guard case .released = output.values[0] else { return XCTFail("Missing device release acknowledgement") }
        inbox.release(); scheduler.drain(); XCTAssertEqual(output.count, 1)
    }
    private func frame(width: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &value), kCVReturnSuccess)
        return try XCTUnwrap(value)
    }
}
private final class MediaInboxScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    var count: Int { lock.withLock { pending.count } }
    func schedule(_ work: @escaping @Sendable () -> Void) { lock.withLock { pending.append(work) } }
    func drain() { let work = lock.withLock { let result = pending; pending = []; return result }; for value in work { value() } }
}
private final class MediaInboxOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [TelegramCallMediaDelivery] = []
    var values: [TelegramCallMediaDelivery] { lock.withLock { received } }
    var count: Int { lock.withLock { received.count } }
    func append(_ value: TelegramCallMediaDelivery) { lock.withLock { received.append(value) } }
}

import XCTest
import CoreVideo
@testable import MakoshApp

@MainActor final class TelegramCallFrameRendererTests: XCTestCase {
    func testBusyRendererPublishesCompletedFrameAndCoalescesWaitingInputs() async throws {
        let entered = expectation(description: "render worker entered")
        let first = expectation(description: "first publication")
        let second = expectation(description: "latest publication")
        let gate = DispatchSemaphore(value: 0), records = RenderRecords()
        let renderer = TelegramCallFrameRenderer(render: { frame in
            XCTAssertFalse(Thread.isMainThread)
            let width = CVPixelBufferGetWidth(frame)
            records.render(width)
            if width == 2 {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            }
            return nil
        }, publish: { token, _ in
            if records.publish(token) == 1 { first.fulfill() } else { second.fulfill() }
        })
        defer { renderer.close(); gate.signal() }
        renderer.submit(try frame(2))
        await fulfillment(of: [entered], timeout: 2)
        renderer.submit(try frame(4)); renderer.submit(try frame(6))
        gate.signal()
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(records.widths, [2])
        // A faster producer must not starve presentation by invalidating every
        // completed frame while another frame is waiting to be rendered.
        XCTAssertTrue(renderer.isCurrent(try XCTUnwrap(records.tokens.first)))
        renderer.acknowledge()
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(records.widths, [2, 6])
        XCTAssertTrue(renderer.isCurrent(try XCTUnwrap(records.tokens.last)))
        XCTAssertFalse(renderer.isCurrent(try XCTUnwrap(records.tokens.first)))
        renderer.acknowledge()
    }

    func testCloseRejectsCompletedRenderAndFurtherFrames() async throws {
        let entered = expectation(description: "render worker entered")
        let finished = expectation(description: "retired render returned")
        let gate = DispatchSemaphore(value: 0), records = RenderRecords()
        let renderer = TelegramCallFrameRenderer(render: { frame in
            records.render(CVPixelBufferGetWidth(frame)); entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return nil
        }, publish: { token, _ in _ = records.publish(token); finished.fulfill() })
        renderer.submit(try frame(2))
        await fulfillment(of: [entered], timeout: 2)
        renderer.close(); renderer.submit(try frame(6)); gate.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(renderer.isCurrent(try XCTUnwrap(records.tokens.first)))
        renderer.acknowledge()
        XCTAssertEqual(records.widths, [2])
    }
    private func frame(_ width: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 2, kCVPixelFormatType_32BGRA, nil, &value), kCVReturnSuccess)
        return try XCTUnwrap(value)
    }
}
private final class RenderRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var rendered: [Int] = [], published: [UUID] = []
    var widths: [Int] { lock.withLock { rendered } }
    var tokens: [UUID] { lock.withLock { published } }
    func render(_ width: Int) { lock.withLock { rendered.append(width) } }
    func publish(_ token: UUID) -> Int { lock.withLock { published.append(token); return published.count } }
}

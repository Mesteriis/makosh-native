import XCTest
import AppKit
@testable import MakoshApp

@MainActor final class TelegramCallWindowPresentationTests: XCTestCase {
    func testDetachedProbeCannotPublishAfterDismantle() async {
        let view = CallWindowVisibilityProbe()
        var events: [Bool] = []
        view.receive = { events.append($0) }
        view.updateVisibility(); view.stop()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(events.isEmpty,"A detached old probe must not hide a replacement call window")
    }
}

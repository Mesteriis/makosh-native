import AppKit
import XCTest
@testable import MakoshApp

/// Stands in for SwiftUI's own window delegate: every other call must still reach it.
private final class RecordingDelegate: NSObject, NSWindowDelegate {
    var resized = 0
    func windowDidResize(_ notification: Notification) { resized += 1 }
}

@MainActor final class WorkspaceWindowKeeperTests: XCTestCase {
    func testClosingTheWorkspaceWindowHidesItAndReopenShowsTheSameWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable, .resizable], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let original = RecordingDelegate()
        window.delegate = original
        let keeper = WorkspaceWindowKeeper()
        keeper.keep(window)
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible, "closing hides the window")
        XCTAssertTrue(keeper.window === window, "the window and its services stay alive")
        window.setContentSize(NSSize(width: 500, height: 320))
        XCTAssertGreaterThan(original.resized, 0, "SwiftUI's delegate still receives everything else")
        XCTAssertTrue(keeper.reopen(), "a reopen shows the kept window")
        XCTAssertTrue(window.isVisible)
        keeper.keep(window)
        XCTAssertTrue(window.delegate === keeper.proxy, "keeping twice installs the proxy once")
    }

    func testReopenWithoutAKeptWindowLetsTheSystemOpenOne() {
        XCTAssertFalse(WorkspaceWindowKeeper().reopen())
    }
}

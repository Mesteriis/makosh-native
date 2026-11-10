import AppKit
import XCTest
@testable import MakoshApp

@MainActor
final class ApplicationLifetimeTests: XCTestCase {
    func testAppDelegateKeepsRunningAfterLastWindowClosed() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    /// The Dock or a second launch shows the one kept workspace window instead of
    /// letting SwiftUI open another; a second window would run a second set of
    /// window-owned services.
    func testReopenShowsTheKeptWindowInsteadOfANewOne() {
        let delegate = AppDelegate()
        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false),
            "without a kept window the system presents the single workspace window")
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false  // the test owns it
        delegate.windowKeeper.keep(window)
        window.orderOut(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertTrue(window.isVisible, "the kept window comes back")
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        window.orderOut(nil)
    }

    func testCalendarHostOutlivesWindow() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate.calendar === delegate.calendar, "one calendar host per process, owned by the delegate")
    }
}

@MainActor final class CalendarQAKeychainTests: XCTestCase {
    func testSyntheticCalendarNeverTouchesTheSystemKeychain() {
        XCTAssertFalse(CalendarHost(synthetic: [:]).usesSystemKeychain, "QA keys stay in memory")
        XCTAssertTrue(CalendarHost().usesSystemKeychain)
    }
}

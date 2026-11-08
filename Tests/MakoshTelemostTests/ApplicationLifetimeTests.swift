import AppKit
import XCTest
@testable import MakoshApp

@MainActor
final class ApplicationLifetimeTests: XCTestCase {
    func testAppDelegateKeepsRunningAfterLastWindowClosed() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
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

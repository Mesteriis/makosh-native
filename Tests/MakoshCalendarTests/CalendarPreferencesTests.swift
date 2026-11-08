import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarPreferencesTests: XCTestCase {
    func testDefaultsAndRoundTrip() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let defaults = try await store.preferences()
        XCTAssertEqual(defaults, CalendarPreferences())
        XCTAssertEqual(defaults.view, .week)
        XCTAssertEqual(defaults.horizonDays, 90)
        XCTAssertEqual(defaults.pollSeconds, 120)
        XCTAssertEqual(defaults.subscriptionPollSeconds, 3600)
        XCTAssertEqual(defaults.defaultReminderMinutes, 10)
        XCTAssertEqual(defaults.maxWritesPerPass, 50)
        var changed = defaults
        changed.view = .day
        changed.showTasks = false
        changed.lastCollectionID = UUID()
        try await store.savePreferences(changed)
        let read = try await store.preferences()
        XCTAssertEqual(read, changed)
    }

    func testUnknownKeysAreToleratedAndMissingKeysDefault() throws {
        let json = #"{"view":"month","future":"ignored"}"#
        let decoded = try JSONDecoder().decode(CalendarPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.view, .month)
        XCTAssertEqual(decoded.pollSeconds, 120)
    }
}

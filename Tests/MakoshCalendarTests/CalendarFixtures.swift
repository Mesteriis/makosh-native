import Foundation
@testable import MakoshCalendar

extension CalendarEvent {
    /// A timed event today in UTC from `start` to `end` o'clock.
    static func fixture(
        start: Int, end: Int, collectionID: UUID = UUID(), day: Date = Date(timeIntervalSince1970: 1_794_096_000)
    ) -> CalendarEvent {
        let from = day.addingTimeInterval(TimeInterval(start * 3600)), to = day.addingTimeInterval(TimeInterval(end * 3600))
        return CalendarEvent(
            collectionID: collectionID, uid: UUID().uuidString, title: "Событие", time: .timed(start: from, end: to, timeZone: nil))
    }
}

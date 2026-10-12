import Foundation

/// A calendar jump uses local midnight, with an exact Telegram timestamp. Never
/// clamp an unrepresentable day to a different date or assume 86,400-second days.
func telegramSearchDayTimestamp(_ date: Date, calendar: Calendar) -> Int32? {
    guard date.timeIntervalSince1970.isFinite else { return nil }
    let seconds = calendar.startOfDay(for: date).timeIntervalSince1970
    guard seconds.isFinite else { return nil }
    return Int32(exactly: seconds)
}

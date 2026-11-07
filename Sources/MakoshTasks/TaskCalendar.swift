import Foundation

/// One month of the sidebar calendar: a 7-column grid of days with leading blanks.
public struct TaskCalendarMonth: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let firstWeekday: Int
    public let cells: [Date?]
    public let weekdayTitles: [String]
    public let title: String
    private let calendar: Calendar

    public static func make(year: Int, month: Int, firstWeekday: Int, calendar: Calendar) -> TaskCalendarMonth {
        var calendar = calendar
        calendar.firstWeekday = firstWeekday
        let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let days = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let leading = (calendar.component(.weekday, from: first) - firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in 1...days { cells.append(calendar.date(from: DateComponents(year: year, month: month, day: day))) }
        while cells.count % 7 != 0 { cells.append(nil) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ru_RU")
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"]
        let titles = (0..<7).map { symbols[($0 + firstWeekday - 1) % 7].capitalized }
        formatter.dateFormat = "LLLL yyyy"
        let title = formatter.string(from: first).capitalized
        return TaskCalendarMonth(
            year: year, month: month, firstWeekday: firstWeekday, cells: cells, weekdayTitles: titles, title: title, calendar: calendar)
    }

    public static func containing(_ date: Date, firstWeekday: Int, calendar: Calendar) -> TaskCalendarMonth {
        make(
            year: calendar.component(.year, from: date), month: calendar.component(.month, from: date), firstWeekday: firstWeekday,
            calendar: calendar)
    }

    public func next() -> TaskCalendarMonth {
        month == 12
            ? Self.make(year: year + 1, month: 1, firstWeekday: firstWeekday, calendar: calendar)
            : Self.make(year: year, month: month + 1, firstWeekday: firstWeekday, calendar: calendar)
    }

    public func previous() -> TaskCalendarMonth {
        month == 1
            ? Self.make(year: year - 1, month: 12, firstWeekday: firstWeekday, calendar: calendar)
            : Self.make(year: year, month: month - 1, firstWeekday: firstWeekday, calendar: calendar)
    }

    public static func == (lhs: TaskCalendarMonth, rhs: TaskCalendarMonth) -> Bool {
        lhs.year == rhs.year && lhs.month == rhs.month && lhs.firstWeekday == rhs.firstWeekday
    }
}

public enum TaskCalendarRules {
    /// Days (start of day) that carry a due date, for the dots.
    public static func dueDays(_ tasks: [Task], calendar: Calendar) -> Set<Date> {
        Set(tasks.compactMap { task in task.due.map { calendar.startOfDay(for: $0) } })
    }

    /// The days the active agenda covers, for the highlight; the overdue agenda has no range.
    public static func agendaRange(_ agenda: TasksAgenda?, today: Date, calendar: Calendar) -> ClosedRange<Date>? {
        let start = calendar.startOfDay(for: today)
        let days: Int
        switch agenda {
        case .today?: days = 0
        case .tomorrow?: days = 1
        case .week?: days = 7
        case .month?: days = 30
        default: return nil
        }
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        return start...end
    }
}

import Foundation

/// The span the section shows: a day, a week starting on the configured weekday, or a month.
package struct CalendarPeriod: Equatable, Sendable {
    package var mode: CalendarViewMode
    package var anchor: Date

    package init(mode: CalendarViewMode, anchor: Date) {
        self.mode = mode
        self.anchor = anchor
    }

    package func interval(calendar: Foundation.Calendar) -> DateInterval {
        switch mode {
        case .day: return calendar.dateInterval(of: .day, for: anchor)!
        case .week: return calendar.dateInterval(of: .weekOfYear, for: anchor)!
        case .month: return calendar.dateInterval(of: .month, for: anchor)!
        }
    }

    package func days(calendar: Foundation.Calendar) -> [Date] {
        let span = interval(calendar: calendar)
        var result: [Date] = []
        var day = span.start
        while day < span.end {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    package func moved(by steps: Int, calendar: Foundation.Calendar) -> CalendarPeriod {
        let next: Date
        switch mode {
        case .day: next = calendar.date(byAdding: .day, value: steps, to: anchor)!
        case .week: next = calendar.date(byAdding: .day, value: 7 * steps, to: anchor)!
        case .month: next = calendar.date(byAdding: .month, value: steps, to: anchor)!
        }
        return CalendarPeriod(mode: mode, anchor: next)
    }
}

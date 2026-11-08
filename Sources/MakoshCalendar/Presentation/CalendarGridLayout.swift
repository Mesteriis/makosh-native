import Foundation

/// One block in a day column: which side-by-side column it takes and its minutes in that day.
package struct CalendarGridItem: Equatable, Identifiable, Sendable {
    package let id: String
    package let occurrence: CalendarOccurrence
    package var column: Int
    package var columns: Int
    package let startMinute: Int
    package let endMinute: Int
    package let clippedTop: Bool
    package let clippedBottom: Bool
}

package enum CalendarGridLayout {
    /// Timed occurrences of one day; events across midnight are cut at the day's edges.
    /// Overlapping blocks form clusters, and each cluster shares its columns greedily.
    package static func layout(day: Date, occurrences: [CalendarOccurrence], calendar: Foundation.Calendar) -> [CalendarGridItem] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        var items: [CalendarGridItem] = occurrences.compactMap { occurrence in
            guard case .timed = occurrence.time, occurrence.start < dayEnd,
                occurrence.end > dayStart || occurrence.start == occurrence.end && occurrence.start >= dayStart
            else { return nil }
            let start = max(occurrence.start, dayStart), end = min(occurrence.end, dayEnd)
            let startMinute = Int(start.timeIntervalSince(dayStart) / 60)
            let endMinute = max(startMinute + 1, Int((end.timeIntervalSince(dayStart) / 60).rounded(.up)))
            return CalendarGridItem(
                id: "\(occurrence.eventID.uuidString)-\(Int(occurrence.key.timeIntervalSince1970))-\(Int(dayStart.timeIntervalSince1970))",
                occurrence: occurrence, column: 0, columns: 1, startMinute: startMinute, endMinute: min(endMinute, 1440),
                clippedTop: occurrence.start < dayStart, clippedBottom: occurrence.end > dayEnd)
        }
        items.sort { ($0.startMinute, -$0.endMinute, $0.id) < ($1.startMinute, -$1.endMinute, $1.id) }
        var clusterStart = 0, clusterEnd = -1
        var columnEnds: [Int] = []
        func close(_ upTo: Int) {
            guard clusterStart < upTo else { return }
            for index in clusterStart..<upTo { items[index].columns = columnEnds.count }
        }
        for index in items.indices {
            if items[index].startMinute >= clusterEnd {
                close(index)
                clusterStart = index
                columnEnds = []
            }
            if let free = columnEnds.firstIndex(where: { $0 <= items[index].startMinute }) {
                items[index].column = free
                columnEnds[free] = items[index].endMinute
            } else {
                items[index].column = columnEnds.count
                columnEnds.append(items[index].endMinute)
            }
            clusterEnd = max(clusterEnd, items[index].endMinute)
        }
        close(items.count)
        return items
    }

    /// For each day, the all-day occurrences covering it (compared as dates, never instants).
    package static func allDay(days: [Date], occurrences: [CalendarOccurrence], calendar: Foundation.Calendar) -> [[CalendarOccurrence]] {
        days.map { date in
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let day = CalendarDay(year: c.year!, month: c.month!, day: c.day!)
            return occurrences.filter { occurrence in
                guard case .allDay(let start, let end) = occurrence.time else { return false }
                return start <= day && day < end
            }
        }
    }
}

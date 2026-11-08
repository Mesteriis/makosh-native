import Foundation

/// One occurrence of an event: a single event yields one, a series yields
/// one per matching date. `key` is the occurrence's start by the series,
/// before any override moved it; overrides and busy copies refer to it.
public struct CalendarOccurrence: Equatable, Sendable {
    public let eventID: UUID
    public let collectionID: UUID
    public let time: CalendarEventTime
    public let key: Date

    public init(eventID: UUID, collectionID: UUID, time: CalendarEventTime, key: Date) {
        self.eventID = eventID
        self.collectionID = collectionID
        self.time = time
        self.key = key
    }

    public var start: Date {
        switch time {
        case .timed(let start, _, _): start
        case .allDay(let start, _): CalendarRecurrenceExpander.midnight(start)
        }
    }
    public var end: Date {
        switch time {
        case .timed(_, let end, _): end
        case .allDay(_, let end): CalendarRecurrenceExpander.midnight(end)
        }
    }
}

/// Expands RRULE series in the event's own time zone, so local time survives
/// daylight-saving changes. Supports FREQ DAILY/WEEKLY/MONTHLY/YEARLY with
/// INTERVAL, COUNT, UNTIL, BYDAY (numbered for monthly/yearly), BYMONTHDAY,
/// BYMONTH and WKST; anything else yields the first occurrence only.
public enum CalendarRecurrenceExpander {
    public static let limit = 5000
    static let iterationLimit = 200_000

    struct Rule {
        enum Frequency: String { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
        var frequency: Frequency
        var interval = 1
        var count: Int?
        var until: String?
        var byDay: [(ordinal: Int?, weekday: Int)] = []
        var byMonthDay: [Int] = []
        var byMonth: [Int] = []
        var weekStart = 2
    }

    /// Weekday numbers follow `Calendar`: 1 = Sunday … 7 = Saturday.
    static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    static func parse(_ text: String) -> Rule? {
        var parts: [String: String] = [:]
        for part in text.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            parts[pair[0].uppercased()] = String(pair[1])
        }
        let supported: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "WKST"]
        guard Set(parts.keys).isSubset(of: supported), let frequency = parts["FREQ"].flatMap({ Rule.Frequency(rawValue: $0.uppercased()) })
        else { return nil }
        var rule = Rule(frequency: frequency)
        if let value = parts["INTERVAL"] {
            guard let interval = Int(value), interval > 0 else { return nil }
            rule.interval = interval
        }
        if let value = parts["COUNT"] {
            guard let count = Int(value), count > 0 else { return nil }
            rule.count = count
        }
        rule.until = parts["UNTIL"]
        if let value = parts["BYDAY"] {
            for item in value.split(separator: ",") {
                let code = String(item.suffix(2)).uppercased(), prefix = item.dropLast(2)
                guard let weekday = weekdays[code] else { return nil }
                if prefix.isEmpty {
                    rule.byDay.append((nil, weekday))
                } else {
                    guard let ordinal = Int(prefix), ordinal != 0, frequency == .monthly || frequency == .yearly else { return nil }
                    rule.byDay.append((ordinal, weekday))
                }
            }
        }
        if let value = parts["BYMONTHDAY"] {
            for item in value.split(separator: ",") {
                guard let day = Int(item), day != 0, abs(day) <= 31 else { return nil }
                rule.byMonthDay.append(day)
            }
        }
        if let value = parts["BYMONTH"] {
            for item in value.split(separator: ",") {
                guard let month = Int(item), (1...12).contains(month) else { return nil }
                rule.byMonth.append(month)
            }
        }
        if let value = parts["WKST"] {
            guard let weekday = weekdays[value.uppercased()] else { return nil }
            rule.weekStart = weekday
        }
        return rule
    }

    public static func unsupported(rrule: String) -> Bool { parse(rrule) == nil }

    static func midnight(_ day: CalendarDay) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
    }

    public static func occurrences(of master: CalendarEvent, overrides: [CalendarEvent], in window: DateInterval) -> [CalendarOccurrence] {
        func overlaps(_ occurrence: CalendarOccurrence) -> Bool {
            occurrence.end > window.start && occurrence.start < window.end
                || (occurrence.start == occurrence.end && occurrence.start >= window.start && occurrence.start < window.end)
        }
        let first = CalendarOccurrence(
            eventID: master.id, collectionID: master.collectionID, time: master.time, key: start(of: master.time))
        guard let recurrence = master.recurrence else { return overlaps(first) ? [first] : [] }
        guard let rule = parse(recurrence.rrule) else { return overlaps(first) ? [first] : [] }

        var calendar = Calendar(identifier: .gregorian)
        let allDay: Bool
        let duration: TimeInterval
        var dayLength = 0
        switch master.time {
        case .timed(let start, let end, let zone):
            calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
            allDay = false
            duration = end.timeIntervalSince(start)
        case .allDay(let start, let end):
            calendar.timeZone = TimeZone(identifier: "UTC")!
            allDay = true
            duration = 0
            dayLength = max(1, days(from: start, to: end))
        }
        calendar.firstWeekday = rule.weekStart
        let dtstart: Date
        switch master.time {
        case .timed(let start, _, _): dtstart = start
        case .allDay(let start, _): dtstart = calendar.date(from: DateComponents(year: start.year, month: start.month, day: start.day))!
        }
        let time = calendar.dateComponents([.hour, .minute, .second], from: dtstart)
        let until = rule.until.flatMap { untilDate($0, calendar: calendar, allDay: allDay) }

        let excluded = Set(recurrence.exdates.map { allDay ? dayKey(of: $0, in: .current) : String($0.timeIntervalSince1970) })
        var byKey: [String: CalendarEvent] = [:]
        for override in overrides {
            guard let id = override.recurrenceID else { continue }
            byKey[allDay ? dayKey(of: id, in: .current) : String(id.timeIntervalSince1970)] = override
        }

        var result: [CalendarOccurrence] = []
        var produced = 0
        var period = 0
        var iterations = 0
        outer: while iterations < iterationLimit {
            iterations += 1
            let candidates = self.candidates(period: period, rule: rule, dtstart: dtstart, time: time, calendar: calendar)
            period += 1
            guard let candidates else { break }
            for candidate in candidates where candidate >= dtstart {
                if let until, candidate > until { break outer }
                if let count = rule.count, produced >= count { break outer }
                produced += 1
                if candidate >= window.end { break outer }
                let occurrenceTime: CalendarEventTime
                let key: String
                if allDay {
                    let components = calendar.dateComponents([.year, .month, .day], from: candidate)
                    let day = CalendarDay(year: components.year!, month: components.month!, day: components.day!)
                    occurrenceTime = .allDay(start: day, endExclusive: ICalendar.adding(days: dayLength, to: day))
                    key = dayKey(day)
                } else {
                    guard case .timed(_, _, let zone) = master.time else { continue }
                    occurrenceTime = .timed(start: candidate, end: candidate.addingTimeInterval(duration), timeZone: zone)
                    key = String(candidate.timeIntervalSince1970)
                }
                if excluded.contains(key) { continue }
                let seriesKey = allDay ? midnight(dayFrom(key)) : candidate
                var occurrence = CalendarOccurrence(
                    eventID: master.id, collectionID: master.collectionID, time: occurrenceTime, key: seriesKey)
                if let override = byKey.removeValue(forKey: key) {
                    if override.status == .cancelled || override.deletedAt != nil { continue }
                    occurrence = CalendarOccurrence(
                        eventID: override.id, collectionID: override.collectionID, time: override.time, key: seriesKey)
                }
                if overlaps(occurrence) {
                    result.append(occurrence)
                    if result.count >= limit { break outer }
                }
            }
        }
        // Overrides whose original date the rule does not produce still show where they now are.
        for override in byKey.values where override.status != .cancelled && override.deletedAt == nil {
            let occurrence = CalendarOccurrence(
                eventID: override.id, collectionID: override.collectionID, time: override.time, key: override.recurrenceID!)
            if overlaps(occurrence), result.count < limit { result.append(occurrence) }
        }
        return result.sorted { $0.start < $1.start }
    }

    static func start(of time: CalendarEventTime) -> Date {
        switch time {
        case .timed(let start, _, _): start
        case .allDay(let start, _): midnight(start)
        }
    }

    static func days(from start: CalendarDay, to end: CalendarDay) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let a = calendar.date(from: DateComponents(year: start.year, month: start.month, day: start.day))!
        let b = calendar.date(from: DateComponents(year: end.year, month: end.month, day: end.day))!
        return calendar.dateComponents([.day], from: a, to: b).day ?? 1
    }

    static func dayKey(_ day: CalendarDay) -> String { ICalendar.dayString(day) }
    static func dayKey(of date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return dayKey(CalendarDay(year: c.year!, month: c.month!, day: c.day!))
    }
    static func dayFrom(_ key: String) -> CalendarDay {
        CalendarDay(year: Int(key.prefix(4))!, month: Int(key.dropFirst(4).prefix(2))!, day: Int(key.suffix(2))!)
    }

    static func untilDate(_ text: String, calendar: Calendar, allDay: Bool) -> Date? {
        switch ICalendar.moment(text, parameters: [:]) {
        case .instant(let date, _)?: return date
        case .day(let day)?:
            // A date-only UNTIL includes that whole day.
            let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
            return start.addingTimeInterval(86400 - 1)
        case nil: return nil
        }
    }

    /// The candidate starts of one period (a day, week, month or year), in order;
    /// nil when the period cannot be built.
    static func candidates(period: Int, rule: Rule, dtstart: Date, time: DateComponents, calendar: Calendar) -> [Date]? {
        func at(_ day: DateComponents) -> Date? {
            var components = day
            components.hour = time.hour
            components.minute = time.minute
            components.second = time.second
            return calendar.date(from: components)
        }
        let step = period * rule.interval
        let base = calendar.dateComponents([.year, .month, .day, .weekday], from: dtstart)
        switch rule.frequency {
        case .daily:
            guard let day = calendar.date(byAdding: .day, value: step, to: calendar.startOfDay(for: dtstart)) else { return nil }
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if !rule.byMonth.isEmpty, !rule.byMonth.contains(c.month!) { return [] }
            if !rule.byDay.isEmpty, !rule.byDay.contains(where: { $0.weekday == c.weekday! }) { return [] }
            if !rule.byMonthDay.isEmpty, !matchesMonthDay(c, rule.byMonthDay, calendar: calendar) { return [] }
            return at(c).map { [$0] }
        case .weekly:
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: dtstart)?.start,
                let week = calendar.date(byAdding: .day, value: 7 * step, to: weekStart)
            else { return nil }
            let wanted = rule.byDay.isEmpty ? [base.weekday!] : rule.byDay.map(\.weekday)
            var result: [Date] = []
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: week) else { continue }
                let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                if !wanted.contains(c.weekday!) { continue }
                if !rule.byMonth.isEmpty, !rule.byMonth.contains(c.month!) { continue }
                if let date = at(c) { result.append(date) }
            }
            return result
        case .monthly:
            guard let first = calendar.date(from: DateComponents(year: base.year, month: base.month, day: 1)),
                let month = calendar.date(byAdding: .month, value: step, to: first)
            else { return nil }
            let c = calendar.dateComponents([.year, .month], from: month)
            if !rule.byMonth.isEmpty, !rule.byMonth.contains(c.month!) { return [] }
            return monthDays(year: c.year!, month: c.month!, rule: rule, defaultDay: base.day!, calendar: calendar).compactMap(at)
        case .yearly:
            let year = base.year! + step
            let months = rule.byMonth.isEmpty ? [base.month!] : rule.byMonth.sorted()
            var result: [Date] = []
            for month in months {
                result += monthDays(year: year, month: month, rule: rule, defaultDay: base.day!, calendar: calendar).compactMap(at)
            }
            return result.sorted()
        }
    }

    static func matchesMonthDay(_ c: DateComponents, _ days: [Int], calendar: Calendar) -> Bool {
        guard let date = calendar.date(from: DateComponents(year: c.year, month: c.month, day: 1)),
            let count = calendar.range(of: .day, in: .month, for: date)?.count
        else { return false }
        return days.contains { $0 > 0 ? $0 == c.day! : count + $0 + 1 == c.day! }
    }

    static func monthDays(year: Int, month: Int, rule: Rule, defaultDay: Int, calendar: Calendar) -> [DateComponents] {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
            let count = calendar.range(of: .day, in: .month, for: first)?.count
        else { return [] }
        func components(_ day: Int) -> DateComponents { DateComponents(year: year, month: month, day: day) }
        var days: [Int]
        if !rule.byDay.isEmpty {
            var matches = Set<Int>()
            for (ordinal, weekday) in rule.byDay {
                let all = (1...count).filter { day in
                    calendar.component(.weekday, from: calendar.date(from: components(day))!) == weekday
                }
                if let ordinal {
                    let index = ordinal > 0 ? ordinal - 1 : all.count + ordinal
                    if all.indices.contains(index) { matches.insert(all[index]) }
                } else {
                    matches.formUnion(all)
                }
            }
            days = matches.sorted()
            if !rule.byMonthDay.isEmpty {
                days = days.filter { day in rule.byMonthDay.contains { $0 > 0 ? $0 == day : count + $0 + 1 == day } }
            }
        } else if !rule.byMonthDay.isEmpty {
            days = rule.byMonthDay.compactMap { value in
                let day = value > 0 ? value : count + value + 1
                return (1...count).contains(day) ? day : nil
            }.sorted()
        } else {
            days = defaultDay <= count ? [defaultDay] : []
        }
        return days.map(components)
    }
}

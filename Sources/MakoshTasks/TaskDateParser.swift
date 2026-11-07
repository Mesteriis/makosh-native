import Foundation

/// Date tokens of the quick entry, the reference's rules: keywords, weekday
/// names strictly after today, `+Nd/w/m`, a bare day in this or the next
/// month, day.month in this or the next year, a full date, day+month name.
public enum TaskDateParser {
    private static let weekdays: [String: Int] = [
        "вс": 1, "воскресенье": 1, "sun": 1, "sunday": 1,
        "пн": 2, "понедельник": 2, "mon": 2, "monday": 2,
        "вт": 3, "вторник": 3, "tue": 3, "tuesday": 3,
        "ср": 4, "среда": 4, "wed": 4, "wednesday": 4,
        "чт": 5, "четверг": 5, "thu": 5, "thursday": 5,
        "пт": 6, "пятница": 6, "fri": 6, "friday": 6,
        "сб": 7, "суббота": 7, "sat": 7, "saturday": 7,
    ]
    private static let months: [String: Int] = [
        "янв": 1, "jan": 1, "фев": 2, "feb": 2, "мар": 3, "mar": 3, "апр": 4, "apr": 4, "май": 5, "мая": 5, "may": 5,
        "июн": 6, "jun": 6, "июл": 7, "jul": 7, "авг": 8, "aug": 8, "сен": 9, "сент": 9, "sep": 9, "окт": 10, "oct": 10,
        "ноя": 11, "нояб": 11, "nov": 11, "дек": 12, "dec": 12,
    ]

    public static func parse(_ text: String, today: Date, calendar: Calendar) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "ё", with: "е")
        guard !s.isEmpty else { return nil }
        let start = calendar.startOfDay(for: today)
        func shift(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: start) }

        switch s {
        case "сегодня", "today": return start
        case "завтра", "tomorrow": return shift(1)
        case "вчера", "yesterday": return shift(-1)
        default: break
        }
        if let weekday = weekdays[s] {
            var diff = weekday - calendar.component(.weekday, from: start)
            if diff <= 0 { diff += 7 }
            return shift(diff)
        }
        if s.hasPrefix("+"), let unit = s.last, let count = Int(s.dropFirst().dropLast()), count > 0 {
            switch unit {
            case "d": return shift(count)
            case "w": return shift(count * 7)
            case "m": return calendar.date(byAdding: .month, value: count, to: start)
            default: return nil
            }
        }
        if let day = Int(s), s.count <= 2 {
            return nextDayOfMonth(day, from: start, calendar: calendar)
        }
        let separators = CharacterSet(charactersIn: "./-")
        let parts = s.components(separatedBy: separators)
        if parts.count == 2, let day = Int(parts[0]), let month = Int(parts[1]), parts[0].count <= 2, parts[1].count <= 2 {
            return nextDayMonth(day: day, month: month, from: start, calendar: calendar)
        }
        if parts.count == 3, let day = Int(parts[0]), let month = Int(parts[1]), let year = Int(parts[2]), parts[2].count == 4 {
            return exact(year: year, month: month, day: day, calendar: calendar)
        }
        if parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), parts[0].count == 4 {
            return exact(year: year, month: month, day: day, calendar: calendar)
        }
        let digits = s.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 2, let day = Int(digits), let month = months[String(s.dropFirst(digits.count))] {
            return nextDayMonth(day: day, month: month, from: start, calendar: calendar)
        }
        let trailing = s.reversed().prefix { $0.isNumber }
        if !trailing.isEmpty, trailing.count <= 2, let day = Int(String(trailing.reversed())),
            let month = months[String(s.dropLast(trailing.count))]
        {
            return nextDayMonth(day: day, month: month, from: start, calendar: calendar)
        }
        return nil
    }

    private static func exact(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        guard let date = calendar.date(from: parts), calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    private static func nextDayOfMonth(_ day: Int, from start: Date, calendar: Calendar) -> Date? {
        guard (1...31).contains(day) else { return nil }
        let year = calendar.component(.year, from: start), month = calendar.component(.month, from: start)
        if let date = exact(year: year, month: month, day: day, calendar: calendar), date > start { return date }
        let nextMonth = month == 12 ? 1 : month + 1
        return exact(year: month == 12 ? year + 1 : year, month: nextMonth, day: day, calendar: calendar)
    }

    private static func nextDayMonth(day: Int, month: Int, from start: Date, calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let year = calendar.component(.year, from: start)
        if let date = exact(year: year, month: month, day: day, calendar: calendar), date > start { return date }
        return exact(year: year + 1, month: month, day: day, calendar: calendar)
    }
}

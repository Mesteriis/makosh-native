import CryptoKit
import Foundation

/// Recurrence as the reference stores it: a keyword (`daily`, `weekly`,
/// `biweekly`, `monthly`, `yearly`) or an RRULE body. The next occurrence is
/// counted from the day the task is closed, never from its due date.
public enum TaskRecurrence {
    public static let keywords = ["daily", "weekly", "biweekly", "monthly", "yearly"]

    public static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.uppercased().hasPrefix("RRULE:") { value = String(value.dropFirst(6)) }
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if keywords.contains(lower) { return lower }
        if lower == "annual" { return "yearly" }
        guard value.uppercased().hasPrefix("FREQ="), parts(of: value)["FREQ"] != nil else { return nil }
        return value
    }

    /// `(FREQ, INTERVAL, BYDAY, BYMONTH)` of an RRULE body; keywords map to their frequency.
    static func parts(of value: String) -> [String: String] {
        var result: [String: String] = [:]
        for segment in value.split(separator: ";") {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            result[segment[..<equals].uppercased()] = String(segment[segment.index(after: equals)...])
        }
        return result
    }

    private static func frequency(_ value: String) -> (freq: String, interval: Int)? {
        switch value.lowercased() {
        case "daily": return ("DAILY", 1)
        case "weekly": return ("WEEKLY", 1)
        case "biweekly": return ("WEEKLY", 2)
        case "monthly": return ("MONTHLY", 1)
        case "yearly", "annual": return ("YEARLY", 1)
        default:
            let parts = parts(of: value)
            guard let freq = parts["FREQ"]?.uppercased() else { return nil }
            return (freq, max(1, Int(parts["INTERVAL"] ?? "1") ?? 1))
        }
    }

    public static func nextDue(_ value: String, today: Date, calendar: Calendar) -> Date? {
        guard let (freq, interval) = frequency(value) else { return nil }
        let start = calendar.startOfDay(for: today)
        switch freq {
        case "DAILY": return calendar.date(byAdding: .day, value: interval, to: start)
        case "WEEKLY": return calendar.date(byAdding: .day, value: 7 * interval, to: start)
        case "MONTHLY": return calendar.date(byAdding: .month, value: interval, to: start)
        case "YEARLY": return calendar.date(byAdding: .year, value: interval, to: start)
        default: return nil
        }
    }

    private static let dayNames = ["MO": "Пн", "TU": "Вт", "WE": "Ср", "TH": "Чт", "FR": "Пт", "SA": "Сб", "SU": "Вс"]
    private static let monthNames = ["янв", "фев", "мар", "апр", "май", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
    private static let ordinals = ["1": "Первый", "2": "Второй", "3": "Третий", "4": "Четвёртый", "-1": "Последний"]

    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if (11...14).contains(mod100) { return many }
        if mod10 == 1 { return one }
        if (2...4).contains(mod10) { return few }
        return many
    }

    /// Russian text for a stored value; unknown shapes come back as they are.
    public static func humanText(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.lowercased() == "biweekly" { return "Каждые 2 недели" }
        guard let (freq, interval) = frequency(value) else { return value }
        let parts = parts(of: value)
        switch freq {
        case "DAILY":
            return interval == 1 ? "Каждый день" : "Каждые \(interval) \(plural(interval, "день", "дня", "дней"))"
        case "WEEKLY":
            let days =
                parts["BYDAY"].map { raw -> String in
                    ": "
                        + raw.split(separator: ",").map { token in
                            let code = String(token.suffix(2)).uppercased()
                            return dayNames[code] ?? String(token)
                        }.joined(separator: ", ")
                } ?? ""
            return interval == 1 ? "Каждую неделю\(days)" : "Каждые \(interval) \(plural(interval, "неделю", "недели", "недель"))\(days)"
        case "MONTHLY":
            if let byDay = parts["BYDAY"], byDay.count >= 3 {
                let day = dayNames[String(byDay.suffix(2)).uppercased()] ?? String(byDay.suffix(2))
                let ordinal = String(byDay.dropLast(2))
                return "\(ordinals[ordinal] ?? ordinal) \(day) каждого месяца"
            }
            return interval == 1 ? "Каждый месяц" : "Каждые \(interval) \(plural(interval, "месяц", "месяца", "месяцев"))"
        case "YEARLY":
            var extra = ""
            if let month = parts["BYMONTH"].flatMap({ Int($0) }), (1...12).contains(month) { extra = " (\(monthNames[month - 1]))" }
            return interval == 1 ? "Каждый год\(extra)" : "Каждые \(interval) \(plural(interval, "год", "года", "лет"))\(extra)"
        default: return value
        }
    }

    /// The namespace every spawned occurrence is derived under.
    static let namespace = UUID(uuidString: "5D3F1B2C-8E6A-4C1F-9A7B-2E4D6F8A0C1E")!

    /// UUID v5 of the parent's id: the next occurrence has one possible id, so
    /// closing a task twice (or on two devices) can never make two copies.
    public static func spawnID(for parent: UUID) -> UUID {
        var data = Data(withUnsafeBytes(of: namespace.uuid) { Array($0) })
        data.append(contentsOf: Array(parent.uuidString.utf8))
        var digest = Array(Insecure.SHA1.hash(data: data).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7], digest[8], digest[9], digest[10],
                digest[11], digest[12], digest[13], digest[14], digest[15]
            ))
    }
}

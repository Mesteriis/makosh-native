import Foundation

/// What the details panel and the edit dialog accept in their fields.
public enum TaskFieldInput {
    /// Adds `https://` when the scheme is missing; anything that is not a web address is dropped.
    public static func url(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return url
    }

    /// «1.5h», «1,5 ч», «2 hours», «30 мин», «2 ч 15 мин», a bare number of minutes.
    public static func estimateMinutes(_ raw: String) -> Int? {
        let text = raw.lowercased().replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let number = Double(text) { return number > 0 ? Int(number.rounded()) : nil }
        let pattern = #"(\d+(?:\.\d+)?)\s*(ч|h|hours?|hrs?|час\w*|мин\w*|m|min\w*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var total = 0.0
        var matched = false
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                let number = Double(text[numberRange])
            else { continue }
            let unit = String(text[unitRange])
            total += unit.hasPrefix("ч") || unit.hasPrefix("h") ? number * 60 : number
            matched = true
        }
        guard matched, total > 0 else { return nil }
        return Int(total.rounded())
    }

    /// «1,5 ч», «30 мин», «2 ч 15 мин».
    public static func estimateText(_ minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) мин" }
        if rest == 0 { return "\(hours) ч" }
        if rest == 30 { return "\(hours),5 ч" }
        return "\(hours) ч \(rest) мин"
    }

    /// The quick-entry date language plus `dd.MM.yyyy` and `yyyy-MM-dd`.
    public static func date(_ raw: String, today: Date, calendar: Calendar) -> Date? {
        TaskDateParser.parse(raw, today: today, calendar: calendar)
    }

    /// Comma-separated names without spaces; a leading slash is forgiven.
    public static func personas(_ raw: String) -> [String] {
        raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: "")
        }.filter { !$0.isEmpty }
    }
}

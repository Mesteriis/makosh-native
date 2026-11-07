import Foundation

/// The quick-entry field as the reference keeps it: tokens become pills as
/// soon as a space follows them; the rest stays text. `composed()` is the
/// one line the parser reads.
public struct TaskQuickEntryChips: Equatable, Sendable {
    public struct Chip: Equatable, Identifiable, Sendable {
        public let kind: TaskQuickEntry.Kind
        public let raw: String
        public var id: String { raw }
        public init(kind: TaskQuickEntry.Kind, raw: String) {
            self.kind = kind
            self.raw = raw
        }
    }

    public var chips: [Chip] = []
    public var text = ""

    public init() {}

    public var isEmpty: Bool { chips.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty }
    public var hasList: Bool { chips.contains { $0.kind == .list } }

    /// The field's new text; a trailing space tries to turn the last word into a chip.
    public mutating func typed(_ newText: String, extractURLs: Bool) {
        text = newText
        guard newText.hasSuffix(" ") else { return }
        commitLastWord(extractURLs: extractURLs)
    }

    /// Backspace on empty text brings the last chip back as text; false when there is none.
    public mutating func backspaceOnEmpty() -> Bool {
        guard text.isEmpty, let last = chips.popLast() else { return false }
        text = last.raw
        return true
    }

    public mutating func remove(at index: Int) {
        guard chips.indices.contains(index) else { return }
        chips.remove(at: index)
    }

    /// Replaces the last word with the suggestion and commits it when it is a token.
    public mutating func accept(_ suggestion: TaskQuickEntrySuggestion) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words.isEmpty { words = [""] }
        words[words.count - 1] = suggestion.replace
        text = words.joined(separator: " ")
        if !commitLastWord(extractURLs: true) { text += " " }
    }

    @discardableResult
    private mutating func commitLastWord(extractURLs: Bool) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = words.last, let kind = TaskQuickEntry.kind(of: last, extractURLs: extractURLs) else { return false }
        if kind == .list, hasList { return false }
        chips.append(Chip(kind: kind, raw: last))
        let remaining = words.dropLast().joined(separator: " ")
        text = remaining.isEmpty ? "" : remaining + " "
        return true
    }

    /// Chips first, then the text, as one parser line.
    public func composed() -> String {
        (chips.map(\.raw) + [text.trimmingCharacters(in: .whitespaces)]).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct TaskQuickEntrySuggestion: Equatable, Identifiable, Sendable {
    public let kind: TaskQuickEntry.Kind
    public let label: String
    public let replace: String
    public let detail: String?
    public var id: String { label }
    public init(kind: TaskQuickEntry.Kind, label: String, replace: String, detail: String?) {
        self.kind = kind
        self.label = label
        self.replace = replace
        self.detail = detail
    }
}

/// Completions for the word being typed, by its marker.
public enum TaskQuickEntrySuggestions {
    static let priorityTitles = ["срочно", "высокий", "обычный", "без приоритета"]
    static let dateHints = ["^сегодня", "^завтра", "^пн", "^вт", "^ср", "^чт", "^пт", "^сб", "^вс"]
    static let recurrenceHints = ["*daily", "*weekly", "*monthly", "*yearly"]

    public static func make(
        for text: String, lists: [String], tags: [String], personas: [String], flows: [String], hasList: Bool, today: Date,
        calendar: Calendar
    ) -> [TaskQuickEntrySuggestion] {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init), !last.isEmpty else {
            return []
        }
        func matching(_ values: [String], prefix: String, kind: TaskQuickEntry.Kind) -> [TaskQuickEntrySuggestion] {
            let query = last.dropFirst(prefix.count).lowercased()
            return values.filter { $0.lowercased().contains(query) }.map {
                TaskQuickEntrySuggestion(kind: kind, label: prefix + $0, replace: prefix + $0, detail: nil)
            }
        }
        if last.hasPrefix(">>") { return matching(flows, prefix: ">>", kind: .flow) }
        if last.hasPrefix("@") { return hasList ? [] : matching(lists, prefix: "@", kind: .list) }
        if last.hasPrefix("#") { return matching(tags, prefix: "#", kind: .tag) }
        if last.hasPrefix("/") { return personas.isEmpty ? [] : matching(personas, prefix: "/", kind: .persona) }
        if last.hasPrefix("!") {
            return ["!1", "!2", "!3", "!4"].filter { $0.hasPrefix(last) }.enumerated().map { _, value in
                TaskQuickEntrySuggestion(kind: .priority, label: value, replace: value, detail: priorityTitles[Int(value.dropFirst())! - 1])
            }
        }
        if last.hasPrefix("^") {
            var results: [TaskQuickEntrySuggestion] = []
            let typed = String(last.dropFirst())
            if !typed.isEmpty, let date = TaskDateParser.parse(typed, today: today, calendar: calendar) {
                results.append(TaskQuickEntrySuggestion(kind: .due, label: last, replace: last, detail: preview(date, calendar: calendar)))
            }
            for hint in dateHints.filter({ $0.hasPrefix(last) && $0 != last }).prefix(7) {
                let date = TaskDateParser.parse(String(hint.dropFirst()), today: today, calendar: calendar)
                results.append(
                    TaskQuickEntrySuggestion(kind: .due, label: hint, replace: hint, detail: date.map { preview($0, calendar: calendar) }))
            }
            return results
        }
        if last.hasPrefix("*") {
            return recurrenceHints.filter { $0.hasPrefix(last) }.map {
                TaskQuickEntrySuggestion(
                    kind: .recurrence, label: $0, replace: $0, detail: TaskRecurrence.humanText(String($0.dropFirst())))
            }
        }
        return []
    }

    /// «→ 8 ноября, вс»
    static func preview(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM"
        let day = formatter.string(from: date)
        formatter.dateFormat = "EEE"
        return "→ \(day), \(formatter.string(from: date).lowercased())"
    }
}

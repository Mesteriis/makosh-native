import Foundation

/// The agenda ranges of the sidebar; each one includes the overdue, as the reference counts them.
public enum TasksAgenda: String, CaseIterable, Sendable {
    case today, tomorrow, week, month, overdue

    public var title: String {
        switch self {
        case .today: "Сегодня"
        case .tomorrow: "Завтра"
        case .week: "Неделя"
        case .month: "Месяц"
        case .overdue: "Просрочено"
        }
    }
}

public struct TasksFilterChip: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case status, agenda, list, tag, persona, flow, day }
    public let id: String
    public let kind: Kind
    public let title: String
}

/// Combinable filters, as in the reference: every field narrows the list;
/// `actualOnly` and `groupByFlow` are display preferences, not filters.
public struct TasksFilters: Equatable, Sendable {
    public var status: TaskStatus?
    public var agenda: TasksAgenda?
    public var list: String?
    public var tag: String?
    public var persona: String?
    public var flow: String?
    public var day: Date?
    public var actualOnly = false
    public var groupByFlow = false

    public init() {}

    /// Anything that narrows the list and takes part in «K найдено» and Esc.
    public var isFiltering: Bool {
        status != nil || agenda != nil || list != nil || tag != nil || persona != nil || flow != nil || day != nil || actualOnly
    }

    public mutating func toggle(status value: TaskStatus) { status = status == value ? nil : value }
    public mutating func toggle(agenda value: TasksAgenda) {
        agenda = agenda == value ? nil : value
        if agenda != nil { day = nil }
    }
    public mutating func toggle(list value: String) { list = list == value ? nil : value }
    public mutating func toggle(tag value: String) { tag = tag == value ? nil : value }
    public mutating func toggle(persona value: String) { persona = persona == value ? nil : value }
    public mutating func toggle(flow value: String) { flow = flow == value ? nil : value }

    /// The calendar's day filter; it replaces the agenda range, and the same day again clears it.
    public mutating func select(day value: Date?) {
        if let value, let day, Calendar.current.isDate(day, inSameDayAs: value) {
            self.day = nil
        } else {
            day = value
        }
        if day != nil { agenda = nil }
    }

    /// Esc's last stage: everything but the display preferences.
    public mutating func clearFilters() {
        status = nil
        agenda = nil
        list = nil
        tag = nil
        persona = nil
        flow = nil
        day = nil
        actualOnly = false
    }

    public var chips: [TasksFilterChip] {
        var chips: [TasksFilterChip] = []
        if let status { chips.append(TasksFilterChip(id: "status", kind: .status, title: TaskStyleText.status(status))) }
        if let agenda { chips.append(TasksFilterChip(id: "agenda", kind: .agenda, title: agenda.title)) }
        if let list { chips.append(TasksFilterChip(id: "list", kind: .list, title: list)) }
        if let tag { chips.append(TasksFilterChip(id: "tag", kind: .tag, title: "#" + tag)) }
        if let persona { chips.append(TasksFilterChip(id: "persona", kind: .persona, title: persona)) }
        if let flow { chips.append(TasksFilterChip(id: "flow", kind: .flow, title: flow)) }
        if let day {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM"
            chips.append(TasksFilterChip(id: "day", kind: .day, title: formatter.string(from: day)))
        }
        return chips
    }

    public mutating func clear(_ kind: TasksFilterChip.Kind) {
        switch kind {
        case .status: status = nil
        case .agenda: agenda = nil
        case .list: list = nil
        case .tag: tag = nil
        case .persona: persona = nil
        case .flow: flow = nil
        case .day: day = nil
        }
    }

    // MARK: Storage

    public init(snapshot: TasksFiltersSnapshot, calendar: Calendar) {
        status = snapshot.status.flatMap(TaskStatus.init(rawValue:))
        agenda = snapshot.agenda.flatMap(TasksAgenda.init(rawValue:))
        list = snapshot.list
        tag = snapshot.tag
        persona = snapshot.persona
        flow = snapshot.flow
        day = snapshot.day.flatMap { Self.day(from: $0, calendar: calendar) }
        actualOnly = snapshot.actualOnly
        groupByFlow = snapshot.groupByFlow
    }

    public func snapshot(calendar: Calendar) -> TasksFiltersSnapshot {
        var value = TasksFiltersSnapshot()
        value.status = status?.rawValue
        value.agenda = agenda?.rawValue
        value.list = list
        value.tag = tag
        value.persona = persona
        value.flow = flow
        value.day = day.map { Self.dayString($0, calendar: calendar) }
        value.actualOnly = actualOnly
        value.groupByFlow = groupByFlow
        return value
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func day(from text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// A sort chip: off → ascending → descending → off.
public struct TasksSortState: Equatable, Sendable {
    public var field: TasksSort
    public var descending: Bool
    public init(field: TasksSort, descending: Bool) {
        self.field = field
        self.descending = descending
    }

    public static func toggled(_ current: TasksSortState?, field: TasksSort) -> TasksSortState? {
        guard let current, current.field == field else { return TasksSortState(field: field, descending: false) }
        return current.descending ? nil : TasksSortState(field: field, descending: true)
    }
}

/// QWERTY ↔ ЙЦУКЕН, so a search typed in the wrong layout still finds its task.
public enum KeyboardLayout {
    private static let latin = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.")
    private static let cyrillic = Array("йцукенгшщзхъфывапролджэячсмитьбю")
    private static let map: [Character: Character] = {
        var value: [Character: Character] = [:]
        for (l, c) in zip(latin, cyrillic) {
            value[l] = c
            value[c] = l
        }
        return value
    }()

    public static func swapped(_ text: String) -> String { String(text.map { map[$0] ?? $0 }) }
}

/// `to:КОД` references, as the reference pastes them for agents.
public enum TaskReference {
    private static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func text(code: String, title: String) -> String { "to:\(code) \(title)" }

    /// Strips `to:`, uppercases and forgives O/I/L; nil when it cannot be a code.
    public static func normalize(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("to:") { value = String(value.dropFirst(3)) }
        value = value.uppercased().replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
        guard (4...26).contains(value.count), value.allSatisfy({ crockford.contains($0) }) else { return nil }
        return value
    }
}

/// A run of consecutive rows: the tasks of one flow, or tasks outside any flow.
public struct TasksFlowGroup: Equatable, Sendable {
    public let flow: String?
    public let tasks: [Task]
}

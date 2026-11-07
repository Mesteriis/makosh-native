import Foundation

public enum TasksSort: String, Codable, CaseIterable, Sendable {
    case priority, status, due, created
}

/// How dates are written in rows and details.
public enum TaskDateFormat: String, Codable, CaseIterable, Sendable {
    case iso, dmy, short, long

    public var title: String {
        switch self {
        case .iso: "2026-04-20"
        case .dmy: "20.04.2026"
        case .short: "20 апр"
        case .long: "20 апреля 2026"
        }
    }

    public func string(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ru_RU")
        switch self {
        case .iso: formatter.dateFormat = "yyyy-MM-dd"
        case .dmy: formatter.dateFormat = "dd.MM.yyyy"
        case .short: formatter.dateFormat = "d MMM"
        case .long: formatter.dateFormat = "d MMMM yyyy"
        }
        return formatter.string(from: date)
    }
}

/// What the focus panel shows; the default set keeps the current task in sight.
public enum TaskFocusModule: String, Codable, CaseIterable, Sendable {
    case timer, presets, controls, waiting, counter, nextSlot, clock
}

public struct TaskFocusConfig: Codable, Equatable, Sendable {
    public var enabled = false
    public var compact = false
    public var modules: Set<TaskFocusModule> = [.timer, .presets, .controls, .waiting]
    public var presets = [15, 30, 45, 60]
    public var breakMinutes = 5
    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        compact = try c.decodeIfPresent(Bool.self, forKey: .compact) ?? false
        modules = try c.decodeIfPresent(Set<TaskFocusModule>.self, forKey: .modules) ?? [.timer, .presets, .controls, .waiting]
        let list = try c.decodeIfPresent([Int].self, forKey: .presets) ?? []
        presets = list.isEmpty ? [15, 30, 45, 60] : list
        breakMinutes = try c.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 5
    }
}

/// The filters as stored: strings, so the model's typed filters can change
/// without rewriting what older builds saved.
public struct TasksFiltersSnapshot: Codable, Equatable, Sendable {
    public var status: String?
    public var agenda: String?
    public var list: String?
    public var tag: String?
    public var persona: String?
    public var flow: String?
    /// `yyyy-MM-dd` of the calendar day filter.
    public var day: String?
    public var actualOnly = false
    public var groupByFlow = false
    public init() {}
}

/// Everything the section remembers between launches. The first part stored
/// `{sort, filter, showCompleted}`; that shape still reads.
public struct TaskPreferences: Codable, Equatable, Sendable {
    public var filters = TasksFiltersSnapshot()
    public var sort: TasksSort?
    public var sortDescending = false
    public var showCompleted = true
    public var condense = false
    public var showSidebar = true
    public var showRightPanel = true
    public var showCalendar = true
    public var showPlanner = false
    public var plannerWidthPercent = 40
    public var collapsedSections: [String] = []
    public var guideCompleted = false
    public var dateFormat: TaskDateFormat = .dmy
    /// `Calendar` weekday numbers: 2 is Monday, 1 is Sunday.
    public var firstWeekday = 2
    public var showBulkBar = true
    public var extractURLs = true
    public var newTaskActiveToday = false
    public var plannerDayStart = 9
    public var plannerDayEnd = 17
    public var plannerStep = 30
    public var focus = TaskFocusConfig()
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case filters, sort, sortDescending, showCompleted, condense, showSidebar, showRightPanel, showCalendar, showPlanner
        case plannerWidthPercent, collapsedSections, guideCompleted, dateFormat, firstWeekday, showBulkBar, extractURLs
        case newTaskActiveToday, plannerDayStart, plannerDayEnd, plannerStep, focus
        case legacyFilter = "filter"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filters = try c.decodeIfPresent(TasksFiltersSnapshot.self, forKey: .filters) ?? TasksFiltersSnapshot()
        sort = try c.decodeIfPresent(TasksSort.self, forKey: .sort)
        sortDescending = try c.decodeIfPresent(Bool.self, forKey: .sortDescending) ?? false
        showCompleted = try c.decodeIfPresent(Bool.self, forKey: .showCompleted) ?? true
        condense = try c.decodeIfPresent(Bool.self, forKey: .condense) ?? false
        showSidebar = try c.decodeIfPresent(Bool.self, forKey: .showSidebar) ?? true
        showRightPanel = try c.decodeIfPresent(Bool.self, forKey: .showRightPanel) ?? true
        showCalendar = try c.decodeIfPresent(Bool.self, forKey: .showCalendar) ?? true
        showPlanner = try c.decodeIfPresent(Bool.self, forKey: .showPlanner) ?? false
        plannerWidthPercent = try c.decodeIfPresent(Int.self, forKey: .plannerWidthPercent) ?? 40
        collapsedSections = try c.decodeIfPresent([String].self, forKey: .collapsedSections) ?? []
        guideCompleted = try c.decodeIfPresent(Bool.self, forKey: .guideCompleted) ?? false
        dateFormat = try c.decodeIfPresent(TaskDateFormat.self, forKey: .dateFormat) ?? .dmy
        firstWeekday = try c.decodeIfPresent(Int.self, forKey: .firstWeekday) ?? 2
        showBulkBar = try c.decodeIfPresent(Bool.self, forKey: .showBulkBar) ?? true
        extractURLs = try c.decodeIfPresent(Bool.self, forKey: .extractURLs) ?? true
        newTaskActiveToday = try c.decodeIfPresent(Bool.self, forKey: .newTaskActiveToday) ?? false
        plannerDayStart = try c.decodeIfPresent(Int.self, forKey: .plannerDayStart) ?? 9
        plannerDayEnd = try c.decodeIfPresent(Int.self, forKey: .plannerDayEnd) ?? 17
        plannerStep = try c.decodeIfPresent(Int.self, forKey: .plannerStep) ?? 30
        focus = try c.decodeIfPresent(TaskFocusConfig.self, forKey: .focus) ?? TaskFocusConfig()
        // The first part's single filter key and its «show completed» switch.
        if let legacy = try c.decodeIfPresent(String.self, forKey: .legacyFilter) {
            switch legacy {
            case "today", "tomorrow", "week", "month", "overdue": filters.agenda = legacy
            case let key where key.hasPrefix("status:"): filters.status = String(key.dropFirst(7))
            case let key where key.hasPrefix("list:"): filters.list = String(key.dropFirst(5))
            case let key where key.hasPrefix("tag:"): filters.tag = String(key.dropFirst(4))
            default: break
            }
            if c.contains(.showCompleted) { filters.actualOnly = !showCompleted }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filters, forKey: .filters)
        try c.encodeIfPresent(sort, forKey: .sort)
        try c.encode(sortDescending, forKey: .sortDescending)
        try c.encode(showCompleted, forKey: .showCompleted)
        try c.encode(condense, forKey: .condense)
        try c.encode(showSidebar, forKey: .showSidebar)
        try c.encode(showRightPanel, forKey: .showRightPanel)
        try c.encode(showCalendar, forKey: .showCalendar)
        try c.encode(showPlanner, forKey: .showPlanner)
        try c.encode(plannerWidthPercent, forKey: .plannerWidthPercent)
        try c.encode(collapsedSections, forKey: .collapsedSections)
        try c.encode(guideCompleted, forKey: .guideCompleted)
        try c.encode(dateFormat, forKey: .dateFormat)
        try c.encode(firstWeekday, forKey: .firstWeekday)
        try c.encode(showBulkBar, forKey: .showBulkBar)
        try c.encode(extractURLs, forKey: .extractURLs)
        try c.encode(newTaskActiveToday, forKey: .newTaskActiveToday)
        try c.encode(plannerDayStart, forKey: .plannerDayStart)
        try c.encode(plannerDayEnd, forKey: .plannerDayEnd)
        try c.encode(plannerStep, forKey: .plannerStep)
        try c.encode(focus, forKey: .focus)
    }
}

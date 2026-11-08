import Foundation

/// One block of a day plan: a task, or time blocked for something else.
/// Times are minutes from midnight; the store writes them as «ЧЧ:ММ».
public struct TaskPlanSlot: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case task, blocked }
    public enum Recurrence: String, Codable, CaseIterable, Sendable { case daily, weekly, biweekly }

    public let id: UUID
    public let planID: UUID
    public var taskID: UUID?
    public var title: String?
    public var start: Int
    public var end: Int
    public var kind: Kind
    public var recurrence: Recurrence?
    /// The calendar this slot becomes an event in; nil means the calendar's default.
    public var calendarID: UUID?
    /// Busy time from the calendar, shown in the planner but never stored or edited here.
    public var external: Bool?

    public init(
        id: UUID = UUID(), planID: UUID, taskID: UUID? = nil, title: String? = nil, start: Int, end: Int, kind: Kind,
        recurrence: Recurrence? = nil, calendarID: UUID? = nil, external: Bool? = nil
    ) {
        self.id = id
        self.planID = planID
        self.taskID = taskID
        self.title = title
        self.start = start
        self.end = end
        self.kind = kind
        self.recurrence = recurrence
        self.calendarID = calendarID
        self.external = external
    }

    public var isExternal: Bool { external == true }
    public var minutes: Int { max(0, end - start) }
    public var range: ClosedRange<Int> { start...max(start, end) }

    public static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]), (0...24).contains(hours), (0..<60).contains(minutes)
        else { return nil }
        return hours * 60 + minutes
    }
}

/// The plan of one day: its hours; the slots hang off it.
public struct TaskDayPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let day: Date
    public var dayStart: Int
    public var dayEnd: Int
    public init(id: UUID = UUID(), day: Date, dayStart: Int, dayEnd: Int) {
        self.id = id
        self.day = day
        self.dayStart = dayStart
        self.dayEnd = dayEnd
    }
}

public struct TaskPlacement: Equatable, Sendable {
    public let taskID: UUID
    public let start: Int
    public let end: Int
    /// The gap a task without an estimate took; written back as its estimate.
    public let fittedEstimate: Int?
}

/// The reference's placement rules, as pure functions over minutes.
public enum TaskPlannerRules {
    public static let defaultEstimate = 60
    public static let minimumEstimate = 15

    public static func snap(_ minutes: Int, step: Int) -> Int {
        let step = max(1, step)
        return Int((Double(minutes) / Double(step)).rounded()) * step
    }

    public static func estimateMinutes(_ task: Task) -> Int {
        guard let estimate = task.estimateMinutes else { return defaultEstimate }
        return max(minimumEstimate, estimate)
    }

    private static func overlaps(_ start: Int, _ duration: Int, _ range: ClosedRange<Int>) -> Bool {
        start < range.upperBound && start + duration > range.lowerBound
    }

    /// A start at or after `start` that avoids `occupied`; when pushing forward
    /// runs past the day's end, the slot goes just before the obstacle instead.
    public static func freeStart(_ start: Int, duration: Int, occupied: [ClosedRange<Int>], dayStart: Int, dayEnd: Int, step: Int) -> Int? {
        guard duration <= dayEnd - dayStart else { return nil }
        var candidate = start
        var changed = true
        while changed {
            changed = false
            for range in occupied where overlaps(candidate, duration, range) {
                candidate = Int((Double(range.upperBound) / Double(max(1, step))).rounded(.up)) * max(1, step)
                changed = true
            }
        }
        if candidate + duration > dayEnd {
            candidate = start
            for range in occupied where overlaps(candidate, duration, range) {
                candidate = Int((Double(range.lowerBound - duration) / Double(max(1, step))).rounded(.down)) * max(1, step)
                break
            }
        }
        let result = max(dayStart, min(candidate, dayEnd - duration))
        return occupied.contains { overlaps(result, duration, $0) } ? nil : result
    }

    /// Where dropped tasks land, one after another from `start`; a task that
    /// cannot be placed without overlap stops the sequence.
    public static func placements(
        taskIDs: [UUID], estimates: [UUID: Int?], at start: Int, occupied: [ClosedRange<Int>], dayStart: Int, dayEnd: Int, step: Int
    ) -> [TaskPlacement] {
        var occupied = occupied.sorted { $0.lowerBound < $1.lowerBound }
        var next = start
        var result: [TaskPlacement] = []
        for id in taskIDs {
            let estimate = estimates[id] ?? nil
            var duration = estimate.map { max(minimumEstimate, $0) } ?? defaultEstimate
            var fitted: Int?
            if estimate == nil {
                var available = dayEnd - next
                for range in occupied {
                    if range.lowerBound <= next, range.upperBound > next {
                        available = 0
                        break
                    }
                    if range.lowerBound >= next { available = min(available, range.lowerBound - next) }
                }
                if available > 0, available < defaultEstimate {
                    duration = available
                    fitted = available
                }
            }
            guard let free = freeStart(next, duration: duration, occupied: occupied, dayStart: dayStart, dayEnd: dayEnd, step: step),
                free + duration <= dayEnd, !occupied.contains(where: { overlaps(free, duration, $0) })
            else { break }
            result.append(TaskPlacement(taskID: id, start: free, end: free + duration, fittedEstimate: fitted))
            occupied.append(free...(free + duration))
            occupied.sort { $0.lowerBound < $1.lowerBound }
            next = free + duration
        }
        return result
    }

    /// How long a blocked slot at `start` may be: an hour, or up to the next slot or the day's end.
    public static func blockedDuration(at start: Int, occupied: [ClosedRange<Int>], dayEnd: Int) -> Int {
        var available = dayEnd - start
        for range in occupied {
            if range.lowerBound <= start, range.upperBound > start { return 0 }
            if range.lowerBound >= start { available = min(available, range.lowerBound - start) }
        }
        return max(0, min(defaultEstimate, available))
    }

    /// Monday to Sunday of the week holding `day`.
    public static func weekDays(containing day: Date, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: day)
        let weekday = calendar.component(.weekday, from: start)
        let offset = weekday == 1 ? -6 : 2 - weekday
        guard let monday = calendar.date(byAdding: .day, value: offset, to: start) else { return [start] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    /// Whether a blocked slot planned on `sourceDay` also shows on `targetDay`.
    public static func recurs(_ slot: TaskPlanSlot, from sourceDay: Date, on targetDay: Date, calendar: Calendar) -> Bool {
        guard slot.kind == .blocked, let recurrence = slot.recurrence else { return false }
        let source = calendar.startOfDay(for: sourceDay), target = calendar.startOfDay(for: targetDay)
        guard source != target else { return false }
        switch recurrence {
        case .daily: return true
        case .weekly: return calendar.component(.weekday, from: source) == calendar.component(.weekday, from: target)
        case .biweekly:
            let days = calendar.dateComponents([.day], from: source, to: target).day ?? 0
            return calendar.component(.weekday, from: source) == calendar.component(.weekday, from: target) && days % 14 == 0
        }
    }

    public static func summary(slots: [TaskPlanSlot], dayStart: Int, dayEnd: Int) -> (plannedMinutes: Int, availableMinutes: Int) {
        let planned = slots.filter { $0.kind == .task }.reduce(0) { $0 + $1.minutes }
        let blocked = slots.filter { $0.kind == .blocked }.reduce(0) { $0 + $1.minutes }
        return (planned, max(0, (dayEnd - dayStart) * 60 - blocked))
    }
}

extension TaskStore {
    /// The plan of a day, created on first use; the settings' hours win over stored ones.
    public func plan(for day: Date, defaults: (start: Int, end: Int), calendar: Calendar) throws -> TaskDayPlan {
        let key = TasksFilters.dayString(day, calendar: calendar)
        if let row = try query("SELECT data FROM \(t("tasks_day_plans")) WHERE date = $1", [key]).first {
            var plan = try decode(TaskDayPlan.self, row[0])
            if plan.dayStart != defaults.start || plan.dayEnd != defaults.end {
                plan.dayStart = defaults.start
                plan.dayEnd = defaults.end
                try execute("UPDATE \(t("tasks_day_plans")) SET data = $2::jsonb WHERE id = $1", [plan.id.uuidString, try encode(plan)])
            }
            return plan
        }
        let plan = TaskDayPlan(day: calendar.startOfDay(for: day), dayStart: defaults.start, dayEnd: defaults.end)
        try execute(
            "INSERT INTO \(t("tasks_day_plans"))(id, date, data) VALUES($1, $2, $3::jsonb)", [plan.id.uuidString, key, try encode(plan)])
        return plan
    }

    private func planID(for day: Date, calendar: Calendar) throws -> UUID? {
        try query("SELECT id FROM \(t("tasks_day_plans")) WHERE date = $1", [TasksFilters.dayString(day, calendar: calendar)]).first
            .flatMap { UUID(uuidString: $0[0]) }
    }

    /// The day's own slots plus recurring blocked slots of other days; slots of
    /// deleted tasks are dropped on the way.
    public func effectiveSlots(for day: Date, planID: UUID?, calendar: Calendar) throws -> [TaskPlanSlot] {
        var own: [TaskPlanSlot] = []
        if let planID {
            try execute(
                """
                DELETE FROM \(t("tasks_day_plan_slots")) WHERE plan_id = $1 AND data->>'kind' = 'task'
                AND (task_id IS NULL OR task_id NOT IN (SELECT id FROM \(t("tasks_tasks")) WHERE deleted_at IS NULL))
                """, [planID.uuidString])
            own = try query(
                "SELECT data FROM \(t("tasks_day_plan_slots")) WHERE plan_id = $1 ORDER BY start_time", [planID.uuidString]
            ).map { try decode(TaskPlanSlot.self, $0[0]) }
        }
        var keys = Set(own.map { "\($0.title ?? "")|\($0.start)|\($0.end)" })
        var result = own
        let rows = try query(
            """
            SELECT s.data, p.date FROM \(t("tasks_day_plan_slots")) s JOIN \(t("tasks_day_plans")) p ON p.id = s.plan_id
            WHERE s.data->>'kind' = 'blocked' AND s.data->>'recurrence' IS NOT NULL AND ($1::uuid IS NULL OR s.plan_id <> $1::uuid)
            """, [planID?.uuidString])
        for row in rows {
            let slot = try decode(TaskPlanSlot.self, row[0])
            guard let source = TasksFilters.day(from: String(row[1].prefix(10)), calendar: calendar),
                TaskPlannerRules.recurs(slot, from: source, on: day, calendar: calendar)
            else { continue }
            let key = "\(slot.title ?? "")|\(slot.start)|\(slot.end)"
            guard keys.insert(key).inserted else { continue }
            result.append(slot)
        }
        return result.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }

    /// A day's slots without creating its plan; for the focus panel and other days.
    public func slots(for day: Date, calendar: Calendar) throws -> [TaskPlanSlot] {
        try effectiveSlots(for: day, planID: planID(for: day, calendar: calendar), calendar: calendar)
    }

    public func slot(id: UUID) throws -> TaskPlanSlot? {
        try query("SELECT data FROM \(t("tasks_day_plan_slots")) WHERE id = $1", [id.uuidString]).first.map {
            try decode(TaskPlanSlot.self, $0[0])
        }
    }

    public func insertSlot(_ slot: TaskPlanSlot) throws {
        try execute(
            """
            INSERT INTO \(t("tasks_day_plan_slots"))(id, plan_id, task_id, start_time, end_time, data)
            VALUES($1, $2, $3, $4, $5, $6::jsonb)
            """,
            [
                slot.id.uuidString, slot.planID.uuidString, slot.taskID?.uuidString, TaskPlanSlot.time(slot.start),
                TaskPlanSlot.time(slot.end), try encode(slot),
            ])
    }

    public func updateSlot(_ slot: TaskPlanSlot) throws {
        try execute(
            "UPDATE \(t("tasks_day_plan_slots")) SET task_id = $2, start_time = $3, end_time = $4, data = $5::jsonb WHERE id = $1",
            [slot.id.uuidString, slot.taskID?.uuidString, TaskPlanSlot.time(slot.start), TaskPlanSlot.time(slot.end), try encode(slot)])
    }

    public func removeSlot(id: UUID) throws { try execute("DELETE FROM \(t("tasks_day_plan_slots")) WHERE id = $1", [id.uuidString]) }

    /// Tasks that have a slot in any plan; the row shows a clock for them.
    public func plannedTaskIDs() throws -> Set<UUID> {
        let rows = try query(
            """
            SELECT DISTINCT s.task_id FROM \(t("tasks_day_plan_slots")) s JOIN \(t("tasks_tasks")) t ON t.id = s.task_id
            WHERE s.data->>'kind' = 'task' AND t.deleted_at IS NULL
            """)
        return Set(rows.compactMap { UUID(uuidString: $0[0]) })
    }
}

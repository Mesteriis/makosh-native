import Foundation

public enum TaskDomainError: Error, Equatable, Sendable {
    case blocked(by: [UUID])
    case cycle
    case invalidPriority
}

/// The local rules, as pure functions over tasks. The reference is
/// TaskOrchestrator's domain: a task whose dependencies are still open is
/// blocked and may only be inbox or cancelled; closing a task activates the
/// dependents it alone was holding back; overdue is strictly before today.
public enum TaskDomain {
    public static let fullCycle: [TaskStatus] = [.inbox, .active, .done, .cancelled]
    public static let blockedCycle: [TaskStatus] = [.inbox, .cancelled]

    public static func nextCycleStatus(_ current: TaskStatus, blocked: Bool) -> TaskStatus {
        let cycle = blocked ? blockedCycle : fullCycle
        guard let index = cycle.firstIndex(of: current) else { return cycle[0] }
        return cycle[(index + 1) % cycle.count]
    }

    /// Dependencies that are still open; a missing task does not block.
    public static func blockers(_ task: Task, resolve: (UUID) -> Task?) -> [Task] {
        task.dependsOn.compactMap { id in
            guard let other = resolve(id), other.deletedAt == nil else { return nil }
            return isClosed(other.status) ? nil : other
        }
    }

    public static func isBlocked(_ task: Task, resolve: (UUID) -> Task?) -> Bool { !blockers(task, resolve: resolve).isEmpty }

    static func isClosed(_ status: TaskStatus) -> Bool { status == .done || status == .cancelled }

    /// True when `taskID` would become reachable from `dependency` by following `dependsOn`.
    public static func wouldCreateCycle(adding dependency: UUID, to taskID: UUID, resolve: (UUID) -> Task?) -> Bool {
        if dependency == taskID { return true }
        var visited: Set<UUID> = []
        var stack = [dependency]
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            guard let task = resolve(current) else { continue }
            for next in task.dependsOn {
                if next == taskID { return true }
                stack.append(next)
            }
        }
        return false
    }

    /// Inbox tasks that depended on `completed` and now have no open blocker left.
    public static func dependentsToActivate(after completed: UUID, among tasks: [Task]) -> [UUID] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tasks.filter { task in
            task.status == .inbox && task.deletedAt == nil && task.dependsOn.contains(completed)
                && blockers(task) { byID[$0] }.isEmpty
        }.map(\.id)
    }

    public static func isOverdue(_ task: Task, today: Date, calendar: Calendar) -> Bool {
        guard let due = task.due, !isClosed(task.status) else { return false }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: today)
    }

    /// Due becomes the day after max(due, today); the counter grows by one.
    public static func postponed(_ task: Task, today: Date, calendar: Calendar) -> Task {
        var value = task
        let base = max(task.due.map { calendar.startOfDay(for: $0) } ?? .distantPast, calendar.startOfDay(for: today))
        value.due = calendar.date(byAdding: .day, value: 1, to: base)
        value.postponed += 1
        return value
    }

    /// Snoozing by an amount: from max(due, today), the counter grows by one.
    public static func snoozed(_ task: Task, days: Int, months: Int, today: Date, calendar: Calendar) -> Task {
        var value = task
        let base = max(task.due.map { calendar.startOfDay(for: $0) } ?? .distantPast, calendar.startOfDay(for: today))
        var due = base
        if days != 0 { due = calendar.date(byAdding: .day, value: days, to: due) ?? due }
        if months != 0 { due = calendar.date(byAdding: .month, value: months, to: due) ?? due }
        value.due = due
        value.postponed += 1
        return value
    }

    /// Snoozing to a day: the counter grows by one.
    public static func snoozed(_ task: Task, until day: Date, calendar: Calendar) -> Task {
        var value = task
        value.due = calendar.startOfDay(for: day)
        value.postponed += 1
        return value
    }

    /// The Monday that starts the next week: never today, so on a Monday it is a week away.
    public static func nextWeekStart(after today: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: start)  // 1 = Sunday … 7 = Saturday
        var ahead = (9 - weekday) % 7
        if ahead == 0 { ahead = 7 }
        return calendar.date(byAdding: .day, value: ahead, to: start) ?? start
    }

    /// The status change itself: blocked tasks refuse active and done, done
    /// stamps completedAt, leaving done clears it, a repeated done is a no-op.
    public static func applying(status: TaskStatus, to task: Task, now: Date, resolve: (UUID) -> Task?) throws -> Task {
        if task.status == status { return task }
        if status == .active || status == .done {
            let open = blockers(task, resolve: resolve)
            if !open.isEmpty { throw TaskDomainError.blocked(by: open.map(\.id)) }
        }
        var value = task
        value.status = status
        value.completedAt = status == .done ? now : nil
        return value
    }
}

import Foundation

/// One task before and after a change.
public struct TaskChange: Equatable, Sendable {
    public let before: Task
    public let after: Task
    public init(before: Task, after: Task) {
        self.before = before
        self.after = after
    }
}

/// A planner slot before and after: `nil` on one side for an added or removed slot.
public struct TaskSlotChange: Equatable, Sendable {
    public let before: TaskPlanSlot?
    public let after: TaskPlanSlot?
    public init(before: TaskPlanSlot?, after: TaskPlanSlot?) {
        self.before = before
        self.after = after
    }
}

/// One reversible step: every task and slot a single action touched, so a
/// bulk action or a planner move comes back with one ⌘Z.
public struct TaskUndoStep: Equatable, Sendable {
    public let changes: [TaskChange]
    public let slots: [TaskSlotChange]
    public let at: Date
    public init(changes: [TaskChange], slots: [TaskSlotChange] = [], at: Date) {
        self.changes = changes
        self.slots = slots
        self.at = at
    }
    public init(change: TaskChange, at: Date) { self.init(changes: [change], at: at) }
}

/// The reference's deliberately short memory: five steps, each alive for
/// twelve hours, in memory only. The owner clears it whenever the mirror
/// applies outside changes, so a stale step never reverts what it has not seen.
public struct TaskUndoHistory: Sendable {
    public let limit: Int
    public let lifetime: TimeInterval
    private var steps: [TaskUndoStep] = []

    public init(limit: Int = 5, lifetime: TimeInterval = 12 * 3600) {
        self.limit = limit
        self.lifetime = lifetime
    }

    public var count: Int { steps.count }

    public mutating func record(_ step: TaskUndoStep) {
        steps.append(step)
        if steps.count > limit { steps.removeFirst(steps.count - limit) }
    }

    public mutating func clear() { steps.removeAll() }

    /// The newest step still within its lifetime; expired ones are dropped on the way.
    public mutating func pop(now: Date) -> TaskUndoStep? {
        while let last = steps.popLast() {
            if now.timeIntervalSince(last.at) <= lifetime { return last }
        }
        return nil
    }
}

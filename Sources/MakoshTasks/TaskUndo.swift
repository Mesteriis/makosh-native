import Foundation

/// One reversible change: the task before and after it.
public struct TaskUndoStep: Equatable, Sendable {
    public let taskID: UUID
    public let before: Task
    public let after: Task
    public let at: Date
    public init(taskID: UUID, before: Task, after: Task, at: Date) {
        self.taskID = taskID
        self.before = before
        self.after = after
        self.at = at
    }
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

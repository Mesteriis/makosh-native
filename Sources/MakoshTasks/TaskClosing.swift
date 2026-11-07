import Foundation

/// What closing or reopening a task did besides the task itself.
public struct TaskCloseEffects: Equatable, Sendable {
    public var activated: [UUID] = []
    public var spawned: Task?
    public var resurrected = false
    public var removedSpawn: UUID?
    public init() {}
}

public struct TaskWriteResult: Sendable {
    public let task: Task
    public let effects: TaskCloseEffects
}

/// The reference runs its closing rules on every write path, so the store
/// does the same inside the transaction of the write that changed the status.
extension TaskStore {
    static func spawnMarker(_ parent: Task) -> String { "spawn-of:" + parent.code }
    static func activationMarker(_ completed: Task) -> String { "activated-after:" + completed.code }

    func closingEffects(before: Task, after: Task, actor: TaskActor) throws -> TaskCloseEffects {
        var effects = TaskCloseEffects()
        if after.status == .done, before.status != .done, after.deletedAt == nil {
            effects.activated = try activateDependents(of: after, actor: actor)
            if let recurrence = after.recurrence {
                (effects.spawned, effects.resurrected) = try spawnOccurrence(of: after, recurrence: recurrence, actor: actor)
            }
        } else if before.status == .done, after.status != .done, after.recurrence != nil {
            effects.removedSpawn = try removeUntouchedSpawn(of: after, actor: actor)
        }
        return effects
    }

    private func activateDependents(of completed: Task, actor: TaskActor) throws -> [UUID] {
        let all = try tasks()
        var activated: [UUID] = []
        for id in TaskDomain.dependentsToActivate(after: completed.id, among: all) {
            guard var dependent = all.first(where: { $0.id == id }) else { continue }
            dependent.status = .active
            try update(dependent, expectedRevision: dependent.revision, actor: actor, extraChanged: [Self.activationMarker(completed)])
            activated.append(id)
        }
        return activated
    }

    private func spawnOccurrence(of parent: Task, recurrence: String, actor: TaskActor) throws -> (Task?, Bool) {
        guard let due = TaskRecurrence.nextDue(recurrence, today: now(), calendar: .current) else { return (nil, false) }
        let id = TaskRecurrence.spawnID(for: parent.id)
        let existing = try task(id: id)
        if let existing, existing.deletedAt == nil { return (nil, false) }
        let fresh = Task(
            id: id, code: TaskCode.make(from: UUID()), title: parent.title, status: .active, priority: parent.priority, list: parent.list,
            tags: parent.tags, personas: parent.personas, due: due, estimateMinutes: parent.estimateMinutes, url: parent.url,
            recurrence: recurrence, flowID: parent.flowID, createdAt: now())
        if let existing {
            var revived = fresh.replacing(code: existing.code, createdAt: existing.createdAt)
            revived.revision = existing.revision
            revived.deletedAt = nil
            let written = try update(revived, expectedRevision: existing.revision, actor: actor, extraChanged: [Self.spawnMarker(parent)])
            return (written, true)
        }
        return (try insert(fresh, actor: actor, changed: [Self.spawnMarker(parent)]), false)
    }

    /// A spawn still exactly as the closing left it is withdrawn with the closing.
    private func removeUntouchedSpawn(of parent: Task, actor: TaskActor) throws -> UUID? {
        let id = TaskRecurrence.spawnID(for: parent.id)
        guard var spawn = try task(id: id), spawn.deletedAt == nil, spawn.status == .active else { return nil }
        guard try versions(taskID: id).last?.changedFields.contains(where: { $0.hasPrefix("spawn-of:") }) == true else { return nil }
        spawn.deletedAt = now()
        try update(spawn, expectedRevision: spawn.revision, actor: actor)
        return id
    }
}

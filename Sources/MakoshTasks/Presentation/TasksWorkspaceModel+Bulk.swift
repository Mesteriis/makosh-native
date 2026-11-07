import Foundation

/// A message shown for a moment and kept as the status bar's «last action».
public struct TasksToast: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let at: Date
    public init(id: UUID = UUID(), text: String, at: Date) {
        self.id = id
        self.text = text
        self.at = at
    }
}

/// What a bulk action did; the toasts are built from it.
public struct TaskBulkResult: Equatable, Sendable {
    public var changed = 0
    public var activated: [String] = []
    public var skippedBlocked = 0
    public var spawned = 0
    public init() {}
}

/// The two «до …» targets of the context menu: the start of next week and the day after.
public enum TasksSnoozeTarget: Sendable {
    case monday, tuesday
}

extension TasksWorkspaceModel {
    // MARK: Toasts

    public static let toastLifetime: TimeInterval = 3

    public func toast(_ text: String) {
        toasts.append(TasksToast(text: text, at: now()))
        if toasts.count > 5 { toasts.removeFirst(toasts.count - 5) }
        lastAction = text
    }

    public func dismissToast(id: UUID) { toasts.removeAll { $0.id == id } }

    /// Drops toasts older than their lifetime; the ticking task calls it.
    public func expireToasts() {
        let cutoff = now().addingTimeInterval(-Self.toastLifetime)
        toasts.removeAll { $0.at < cutoff }
    }

    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n) " + TaskRecurrence.plural(n, one, few, many)
    }
    public static func tasksCount(_ n: Int) -> String { count(n, "задача", "задачи", "задач") }

    // MARK: Targets

    /// What the keys and the bulk bar act on.
    public var targets: [UUID] { selection.targets(visible: visible.map(\.id)) }

    /// Applies `change` to every task in one transaction and records one undo step.
    /// A change that returns `nil` leaves its task alone.
    @discardableResult
    func bulkEdit(_ ids: [UUID], _ change: @escaping @Sendable (Task) throws -> Task?) async -> TaskBulkResult {
        var result = TaskBulkResult()
        guard !ids.isEmpty else { return result }
        // A task this action's own cascade already moved (a dependent activated by an earlier
        // write) is left as the cascade put it, instead of being cycled from a stale picture.
        let expected = Dictionary(uniqueKeysWithValues: ids.compactMap { id in task(id: id).map { (id, $0.revision) } })
        do {
            let outcome = try await service.store.performInTransaction { store -> ([TaskChange], [TaskCloseEffects]) in
                var changes: [TaskChange] = [], effects: [TaskCloseEffects] = []
                for id in ids {
                    guard let current = try store.task(id: id), current.deletedAt == nil, current.revision == expected[id],
                        let value = try change(current), value != current
                    else { continue }
                    let written = try store.apply(value, expectedRevision: current.revision, actor: .user)
                    changes.append(TaskChange(before: current, after: written.task))
                    effects.append(written.effects)
                }
                return (changes, effects)
            }
            if !outcome.0.isEmpty { undo.record(TaskUndoStep(changes: outcome.0, at: now())) }
            result.changed = outcome.0.count
            let activatedIDs = outcome.1.flatMap(\.activated)
            result.spawned = outcome.1.filter { $0.spawned != nil }.count
            error = nil
            await refresh()
            result.activated = activatedIDs.compactMap { task(id: $0)?.title }
        } catch { self.error = Self.describe(error) }
        return result
    }

    private func report(_ result: TaskBulkResult) {
        if !result.activated.isEmpty { toast("Активированы: " + result.activated.joined(separator: ", ")) }
        if result.skippedBlocked > 0 { toast("Пропущено заблокированных: \(result.skippedBlocked)") }
    }

    // MARK: Status

    /// Space: everything selected is done → back to active; otherwise → done.
    @discardableResult public func bulkToggleDone(ids: [UUID]) async -> TaskBulkResult {
        let targets = ids.compactMap { task(id: $0) }
        guard !targets.isEmpty else { return TaskBulkResult() }
        let allDone = targets.allSatisfy { $0.status == .done }
        if !allDone, targets.allSatisfy({ isBlocked($0) }) {
            toast("Заблокировано: сначала закройте зависимости")
            return TaskBulkResult()
        }
        var result = await bulk(status: allDone ? .active : .done, ids: ids, quiet: true)
        if result.changed > 0 {
            toast((allDone ? "Возвращено: " : "Выполнено: ") + Self.tasksCount(result.changed))
        }
        report(result)
        result.changed = max(result.changed, 0)
        return result
    }

    /// Sets one status on every task; blocked tasks skip `active` and `done`.
    @discardableResult public func bulk(status: TaskStatus, ids: [UUID], quiet: Bool = false) async -> TaskBulkResult {
        let blockedIDs = Set(ids.filter { id in task(id: id).map { isBlocked($0) } ?? false })
        let needsFree = status == .active || status == .done
        let now = now()
        let resolve: @Sendable (UUID) -> Task? = { [tasks] id in tasks.first { $0.id == id } }
        var result = await bulkEdit(ids.filter { !needsFree || !blockedIDs.contains($0) }) { task in
            try TaskDomain.applying(status: status, to: task, now: now, resolve: resolve)
        }
        result.skippedBlocked = needsFree ? blockedIDs.count : 0
        if !quiet {
            if result.changed > 0 { toast("\(TaskStyleText.status(status)): " + Self.tasksCount(result.changed)) }
            report(result)
        }
        return result
    }

    /// S: the next status of the cycle for each task (blocked tasks use the short cycle).
    @discardableResult public func bulkCycle(ids: [UUID]) async -> TaskBulkResult {
        let now = now()
        let resolve: @Sendable (UUID) -> Task? = { [tasks] id in tasks.first { $0.id == id } }
        let result = await bulkEdit(ids) { task in
            let blocked = TaskDomain.isBlocked(task, resolve: resolve)
            return try TaskDomain.applying(
                status: TaskDomain.nextCycleStatus(task.status, blocked: blocked), to: task, now: now, resolve: resolve)
        }
        if result.changed > 0 { toast("Статус: " + Self.tasksCount(result.changed)) }
        report(result)
        return result
    }

    @discardableResult public func bulkPriority(_ priority: Int, ids: [UUID]) async -> TaskBulkResult {
        guard (1...4).contains(priority) else { return TaskBulkResult() }
        let result = await bulkEdit(ids) { task in
            var value = task
            value.priority = priority
            return value
        }
        if result.changed > 0 { toast("Приоритет \(priority): " + Self.tasksCount(result.changed)) }
        return result
    }

    @discardableResult public func bulkDelete(ids: [UUID]) async -> TaskBulkResult {
        let now = now()
        let result = await bulkEdit(ids) { task in
            var value = task
            value.deletedAt = now
            return value
        }
        selection.selected.subtract(ids)
        if result.changed > 0 { toast("Удалено: " + Self.tasksCount(result.changed)) }
        return result
    }

    // MARK: Dates

    /// ⇧P: one day later for tasks that have a due date; the rest are left alone.
    @discardableResult public func bulkPostpone(ids: [UUID]) async -> TaskBulkResult {
        let withDue = ids.filter { task(id: $0)?.due != nil }
        guard !withDue.isEmpty else {
            toast("Нет срока для переноса")
            return TaskBulkResult()
        }
        let today = now(), calendar = calendar
        let result = await bulkEdit(withDue) { TaskDomain.postponed($0, today: today, calendar: calendar) }
        if result.changed > 0 { toast("Отложено: " + Self.tasksCount(result.changed)) }
        return result
    }

    @discardableResult public func bulkSnooze(ids: [UUID], days: Int, months: Int) async -> TaskBulkResult {
        let today = now(), calendar = calendar
        let result = await bulkEdit(ids) { TaskDomain.snoozed($0, days: days, months: months, today: today, calendar: calendar) }
        if result.changed > 0 { toast("Отложено: " + Self.tasksCount(result.changed)) }
        return result
    }

    @discardableResult public func bulkSnooze(ids: [UUID], until target: TasksSnoozeTarget) async -> TaskBulkResult {
        let calendar = calendar
        let monday = TaskDomain.nextWeekStart(after: now(), calendar: calendar)
        let day = target == .monday ? monday : (calendar.date(byAdding: .day, value: 1, to: monday) ?? monday)
        let result = await bulkEdit(ids) { TaskDomain.snoozed($0, until: day, calendar: calendar) }
        if result.changed > 0 { toast("Отложено: " + Self.tasksCount(result.changed)) }
        return result
    }

    @discardableResult public func bulkToday(ids: [UUID]) async -> TaskBulkResult {
        let today = calendar.startOfDay(for: now())
        let result = await bulkEdit(ids) { task in
            var value = task
            value.due = today
            return value
        }
        if result.changed > 0 { toast("На сегодня: " + Self.tasksCount(result.changed)) }
        return result
    }

    // MARK: Single-task helpers of the row

    /// F2: the title alone.
    public func rename(id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task = task(id: id), !trimmed.isEmpty, trimmed != task.title else { return }
        var value = task
        value.title = trimmed
        await update(value)
    }

    /// A copy of every field but the identity, the dates, the notes and the Jira source.
    public func duplicate(id: UUID) async {
        guard let source = task(id: id) else { return }
        let copy = Task(
            title: source.title, status: source.status, priority: source.priority, list: source.list, tags: source.tags,
            personas: source.personas, due: source.due, start: source.start, estimateMinutes: source.estimateMinutes, url: source.url,
            dependsOn: source.dependsOn, recurrence: source.recurrence, flowID: source.flowID, createdAt: now())
        do {
            try await service.store.insert(copy, actor: .user)
            error = nil
            await refresh()
            toast("Задача продублирована")
        } catch { self.error = Self.describe(error) }
    }

    /// `to:КОД Название` per line, in the list's order; for pasting into an AI chat.
    public func referencesText(ids: [UUID]) -> String {
        let wanted = Set(ids)
        var ordered = visible.filter { wanted.contains($0.id) }
        let seen = Set(ordered.map(\.id))
        ordered += ids.compactMap { seen.contains($0) ? nil : task(id: $0) }
        return ordered.map { TaskReference.text(code: $0.code, title: $0.title) }.joined(separator: "\n")
    }
}

/// Russian names of the local statuses, shared by toasts and views.
public enum TaskStyleText {
    public static func status(_ status: TaskStatus) -> String {
        switch status {
        case .inbox: "Входящие"
        case .active: "В работе"
        case .done: "Сделано"
        case .cancelled: "Отменено"
        }
    }
}

// MARK: Flows and personas

extension TasksWorkspaceModel {
    public func saveFlow(_ flow: TaskFlow) async {
        do {
            try await service.store.saveFlow(flow)
            error = nil
            await refresh()
        } catch { self.error = Self.describe(error) }
    }

    /// Drops the card and the name on its tasks; a pinned filter on it is cleared.
    public func deleteFlow(name: String) async {
        do {
            try await service.store.removeFlow(name: name)
            if filters.flow == name { filters.flow = nil }
            error = nil
            await refresh()
            toast("Цепочка удалена")
        } catch { self.error = Self.describe(error) }
    }

    /// «Запустить следующую»: the first ready inbox task of the flow goes active.
    public func startNext(inFlow name: String) async {
        let inFlow = tasks.filter { $0.flowID == name && $0.deletedAt == nil }
        guard let next = TaskFlowRules.nextReady(inFlow, resolve: { self.task(id: $0) }) else { return }
        let result = await bulk(status: .active, ids: [next.id], quiet: true)
        if result.changed > 0 { toast("Задача запущена") }
    }

    public func setFlow(id: UUID, name: String?) async {
        guard let task = task(id: id) else { return }
        var value = task
        value.flowID = name?.trimmingCharacters(in: .whitespaces).isEmpty == false ? name?.trimmingCharacters(in: .whitespaces) : nil
        await update(value)
    }

    public func setPersonas(id: UUID, _ personas: [String]) async {
        guard let task = task(id: id) else { return }
        var value = task
        value.personas = personas.map { $0.replacingOccurrences(of: " ", with: "") }.filter { !$0.isEmpty }
        await update(value)
    }
}

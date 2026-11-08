import Foundation

/// The day planner: one day's plan and slots, drops from the list, moves,
/// resizes, blocked time, and «create a task here».
extension TasksWorkspaceModel {
    var plannerHours: (start: Int, end: Int) { (preferences.plannerDayStart, preferences.plannerDayEnd) }
    var plannerStep: Int { preferences.plannerStep }
    private var occupiedRanges: [ClosedRange<Int>] { slots.map(\.range) }

    /// Loads (and creates) the plan of `plannerDay`.
    public func loadPlanner() async {
        if plannerDay == .distantPast { plannerDay = calendar.startOfDay(for: now()) }
        trackedToday = calendar.startOfDay(for: now())
        let day = plannerDay, hours = plannerHours, calendar = calendar
        do {
            let loaded = try await service.store.performInTransaction { store -> (TaskDayPlan, [TaskPlanSlot], Set<UUID>) in
                let plan = try store.plan(for: day, defaults: hours, calendar: calendar)
                return (plan, try store.effectiveSlots(for: day, planID: plan.id, calendar: calendar), try store.plannedTaskIDs())
            }
            plan = loaded.0
            slots = loaded.1 + (await plannerMirror?.externalBlocks(day: day, planID: loaded.0.id, calendar: calendar) ?? [])
            plannedTaskIDs = loaded.2
            await loadTodaySlots()
        } catch { self.error = Self.describe(error) }
    }

    /// Today's slots, for the focus panel's «until the slot ends» and «next».
    func loadTodaySlots() async {
        let today = calendar.startOfDay(for: now()), calendar = calendar
        todaySlots = (try? await service.store.slots(for: today, calendar: calendar)) ?? []
    }

    /// Midnight: a planner that showed today follows to the new day; a pinned day stays.
    func advancePlannerDay() {
        let today = calendar.startOfDay(for: now())
        guard let tracked = trackedToday, tracked != today else {
            if trackedToday == nil { trackedToday = today }
            return
        }
        trackedToday = today
        if plannerDay == tracked {
            plannerDay = today
            _Concurrency.Task { await loadPlanner() }
        }
    }

    public var plannerSummary: (planned: Int, available: Int) {
        let summary = TaskPlannerRules.summary(slots: slots, dayStart: plannerHours.start, dayEnd: plannerHours.end)
        return (summary.plannedMinutes, summary.availableMinutes)
    }

    public func currentSlot(now date: Date) -> TaskPlanSlot? {
        let minutes = minutesOfDay(date)
        return todaySlots.first { $0.kind == .task && $0.start <= minutes && minutes < $0.end }
    }

    public func nextSlot(now date: Date) -> TaskPlanSlot? {
        let minutes = minutesOfDay(date)
        return todaySlots.filter { $0.kind == .task && $0.start > minutes }.min { $0.start < $1.start }
    }

    func minutesOfDay(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    // MARK: Slots

    /// Tasks dropped at `minutes`: placed one after another; a task already planned is skipped.
    public func dropTasks(_ ids: [UUID], at minutes: Int) async {
        guard let plan else { return }
        let fresh = ids.filter { id in !slots.contains(where: { $0.taskID == id }) && task(id: id) != nil }
        guard !fresh.isEmpty else { return }
        let estimates = Dictionary(uniqueKeysWithValues: fresh.map { ($0, task(id: $0)?.estimateMinutes) })
        let hours = plannerHours
        let placements = TaskPlannerRules.placements(
            taskIDs: fresh, estimates: estimates, at: minutes, occupied: occupiedRanges, dayStart: hours.start * 60, dayEnd: hours.end * 60,
            step: plannerStep)
        let newSlots = placements.map {
            TaskPlanSlot(planID: plan.id, taskID: $0.taskID, start: $0.start, end: $0.end, kind: .task)
        }
        let fitted = placements.compactMap { placement in placement.fittedEstimate.map { (placement.taskID, $0) } }
        do {
            let changes = try await service.store.performInTransaction { store -> [TaskChange] in
                for slot in newSlots { try store.insertSlot(slot) }
                var changes: [TaskChange] = []
                for (taskID, estimate) in fitted {
                    guard var task = try store.task(id: taskID) else { continue }
                    let before = task
                    task.estimateMinutes = estimate
                    changes.append(TaskChange(before: before, after: try store.update(task, expectedRevision: task.revision, actor: .user)))
                }
                return changes
            }
            undo.record(TaskUndoStep(changes: changes, slots: newSlots.map { TaskSlotChange(before: nil, after: $0) }, at: now()))
            if placements.count < fresh.count { toast("Не поместилось: \(fresh.count - placements.count)") }
            await reloadAfterSlotChange()
        } catch { self.error = Self.describe(error) }
    }

    public func moveSlot(id: UUID, to start: Int) async {
        guard let slot = slots.first(where: { $0.id == id }), !slot.isExternal else { return }
        let hours = plannerHours
        let occupied = slots.filter { $0.id != id }.map(\.range)
        guard
            let free = TaskPlannerRules.freeStart(
                max(hours.start * 60, min(start, hours.end * 60 - slot.minutes)), duration: slot.minutes, occupied: occupied,
                dayStart: hours.start * 60, dayEnd: hours.end * 60, step: plannerStep)
        else { return }
        var moved = slot
        moved.start = free
        moved.end = free + slot.minutes
        guard moved != slot else { return }
        await writeSlot(moved, before: slot, taskChange: nil)
    }

    /// The end moves; a task slot's new length becomes the task's estimate.
    public func resizeSlot(id: UUID, end: Int) async {
        guard let slot = slots.first(where: { $0.id == id }), !slot.isExternal else { return }
        var resized = slot
        resized.end = max(slot.start + plannerStep, min(end, plannerHours.end * 60))
        guard resized != slot else { return }
        var change: (Task, Task)?
        if let taskID = slot.taskID, let task = task(id: taskID), task.estimateMinutes != resized.minutes {
            var value = task
            value.estimateMinutes = resized.minutes
            change = (task, value)
        }
        await writeSlot(resized, before: slot, taskChange: change)
    }

    private func writeSlot(_ slot: TaskPlanSlot, before: TaskPlanSlot, taskChange: (Task, Task)?) async {
        do {
            let changes = try await service.store.performInTransaction { store -> [TaskChange] in
                try store.updateSlot(slot)
                guard let (original, value) = taskChange else { return [] }
                let written = try store.update(value, expectedRevision: original.revision, actor: .user)
                return [TaskChange(before: original, after: written)]
            }
            undo.record(TaskUndoStep(changes: changes, slots: [TaskSlotChange(before: before, after: slot)], at: now()))
            await reloadAfterSlotChange()
        } catch { self.error = Self.describe(error) }
    }

    public func removeSlot(id: UUID) async {
        guard let slot = slots.first(where: { $0.id == id }), !slot.isExternal else { return }
        do {
            try await service.store.removeSlot(id: id)
            undo.record(TaskUndoStep(changes: [], slots: [TaskSlotChange(before: slot, after: nil)], at: now()))
            await reloadAfterSlotChange()
        } catch { self.error = Self.describe(error) }
    }

    /// «Занять время»: an hour, or up to the next slot, at `minutes`.
    public func blockSlot(at minutes: Int) async {
        guard let plan else { return }
        let duration = TaskPlannerRules.blockedDuration(at: minutes, occupied: occupiedRanges, dayEnd: plannerHours.end * 60)
        guard duration > 0 else { return }
        let slot = TaskPlanSlot(planID: plan.id, title: "Занято", start: minutes, end: minutes + duration, kind: .blocked)
        do {
            try await service.store.insertSlot(slot)
            await reloadAfterSlotChange()
        } catch { self.error = Self.describe(error) }
    }

    public func unblockSlot(id: UUID) async { await removeSlot(id: id) }

    public func updateSlot(id: UUID, title: String?, recurrence: TaskPlanSlot.Recurrence?) async {
        guard var slot = slots.first(where: { $0.id == id }), slot.kind == .blocked, !slot.isExternal else { return }
        slot.title = title?.trimmingCharacters(in: .whitespaces).isEmpty == false ? title?.trimmingCharacters(in: .whitespaces) : nil
        slot.recurrence = recurrence
        do {
            try await service.store.updateSlot(slot)
            await reloadAfterSlotChange()
        } catch { self.error = Self.describe(error) }
    }

    /// The calendar a slot becomes an event in; nil goes back to the calendar's default.
    public func setSlotCalendar(id: UUID, calendarID: UUID?) async {
        guard var slot = slots.first(where: { $0.id == id }), !slot.isExternal else { return }
        slot.calendarID = calendarID
        do {
            try await service.store.updateSlot(slot)
            await reloadAfterSlotChange()
        } catch { self.error = Self.describe(error) }
    }

    /// Double-click on empty planner space: the next created task lands here.
    public func createTaskHere(at minutes: Int) { pendingSlotStart = minutes }

    /// After a creation with a pending slot time: the task takes the time, as long as the gap allows.
    func taskCreated(_ task: Task) async {
        guard let start = pendingSlotStart, let plan else { return }
        pendingSlotStart = nil
        let duration = min(
            TaskPlannerRules.estimateMinutes(task),
            TaskPlannerRules.blockedDuration(at: start, occupied: occupiedRanges, dayEnd: plannerHours.end * 60))
        guard duration > 0 else { return }
        let slot = TaskPlanSlot(planID: plan.id, taskID: task.id, start: start, end: start + duration, kind: .task)
        do {
            try await service.store.insertSlot(slot)
            await reloadAfterSlotChange()
        } catch { self.error = Self.describe(error) }
    }

    func reloadAfterSlotChange() async {
        let day = plannerDay, planID = plan?.id, calendar = calendar
        do {
            let loaded = try await service.store.performInTransaction { store -> ([TaskPlanSlot], Set<UUID>) in
                (try store.effectiveSlots(for: day, planID: planID, calendar: calendar), try store.plannedTaskIDs())
            }
            if let mirror = plannerMirror {
                let titles = Dictionary(
                    loaded.0.compactMap { slot in slot.taskID.flatMap { id in task(id: id).map { (id, $0.title) } } },
                    uniquingKeysWith: { a, _ in a })
                await mirror.slotsChanged(day: day, slots: loaded.0, titles: titles, calendar: calendar)
                slots = loaded.0 + (await mirror.externalBlocks(day: day, planID: planID ?? UUID(), calendar: calendar))
            } else {
                slots = loaded.0
            }
            plannedTaskIDs = loaded.1
            await loadTodaySlots()
            await refresh()
        } catch { self.error = Self.describe(error) }
    }
}

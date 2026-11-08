import CryptoKit
import Foundation
import MakoshCalendar
import MakoshTasks

/// The Tasks section as the calendar's task column sees it.
struct TasksCalendarFeed: CalendarTaskFeed {
    weak var model: TasksWorkspaceModel?

    @MainActor private static func open(_ model: TasksWorkspaceModel) -> [MakoshTasks.Task] {
        model.tasks.filter { ($0.status == .inbox || $0.status == .active) && $0.deletedAt == nil }
    }

    func tasks(agenda: CalendarTaskAgenda) async -> [CalendarTaskItem] {
        await MainActor.run {
            guard let model else { return [] }
            let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
            let week = calendar.date(byAdding: .day, value: 7, to: today)!
            let items = Self.open(model).filter { task in
                switch agenda {
                case .today:
                    (task.due.map { calendar.startOfDay(for: $0) <= today } ?? false) || (task.due == nil && task.status == .active)
                case .week: task.due.map { calendar.startOfDay(for: $0) < week } ?? false
                case .overdue: TaskDomain.isOverdue(task, today: today, calendar: calendar)
                case .all: true
                }
            }
            return items.sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }.map {
                CalendarTaskItem(
                    id: $0.id, title: $0.title, estimateMinutes: $0.estimateMinutes, due: $0.due,
                    overdue: TaskDomain.isOverdue($0, today: today, calendar: calendar))
            }
        }
    }

    func dueMarks(in interval: DateInterval) async -> [Date: [CalendarTaskItem]] {
        await MainActor.run {
            guard let model else { return [:] }
            let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
            var marks: [Date: [CalendarTaskItem]] = [:]
            for task in Self.open(model) {
                guard let due = task.due, interval.contains(due) else { continue }
                marks[calendar.startOfDay(for: due), default: []].append(
                    CalendarTaskItem(
                        id: task.id, title: task.title, estimateMinutes: task.estimateMinutes, due: due,
                        overdue: TaskDomain.isOverdue(task, today: today, calendar: calendar)))
            }
            return marks
        }
    }

    /// Stretching a task's block writes the task's estimate, as the planner does.
    func setEstimate(taskID: UUID, minutes: Int) async {
        guard let model = await MainActor.run(body: { self.model }), var task = await model.task(id: taskID),
            task.estimateMinutes != minutes
        else { return }
        task.estimateMinutes = minutes
        await model.update(task)
    }
}

/// The planner's slots as calendar events, and the calendar's busy time as planner blocks.
struct CalendarPlannerBridge: TaskPlannerMirror {
    let service: CalendarService
    let defaultCollection: @Sendable () async -> UUID?

    static func stableID(_ eventID: UUID, day: Date) -> UUID {
        let digest = SHA256.hash(data: Data((eventID.uuidString + "/" + String(Int(day.timeIntervalSince1970))).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    func externalBlocks(day: Date, planID: UUID, calendar: Calendar) async -> [TaskPlanSlot] {
        let start = calendar.startOfDay(for: day)
        guard let blocks = try? await service.busyBlocks(day: DateInterval(start: start, duration: 86400)) else { return [] }
        return blocks.map { block in
            let from = max(0, Int(block.start.timeIntervalSince(start) / 60)),
                to = min(1440, Int((block.end.timeIntervalSince(start) / 60).rounded(.up)))
            return TaskPlanSlot(
                id: Self.stableID(block.eventID, day: start), planID: planID, title: block.title, start: from, end: max(from + 1, to),
                kind: .blocked,
                external: true)
        }
    }

    func slotsChanged(day: Date, slots: [TaskPlanSlot], titles: [UUID: String], calendar: Calendar) async {
        guard let fallback = await defaultCollection() else { return }
        let start = calendar.startOfDay(for: day)
        let values = slots.filter { !$0.isExternal }.map { slot in
            CalendarSlotValue(
                id: slot.id, taskID: slot.taskID, title: slot.taskID.flatMap { titles[$0] } ?? slot.title ?? "Занято",
                start: start.addingTimeInterval(TimeInterval(slot.start * 60)), end: start.addingTimeInterval(TimeInterval(slot.end * 60)),
                rrule: slot.recurrence.map {
                    switch $0 {
                    case .daily: "FREQ=DAILY"
                    case .weekly: "FREQ=WEEKLY"
                    case .biweekly: "FREQ=WEEKLY;INTERVAL=2"
                    }
                }, collectionID: slot.calendarID)
        }
        try? await service.syncSlots(day: DateInterval(start: start, duration: 86400), slots: values, defaultCollectionID: fallback)
    }
}

extension TasksHost {
    /// The task column of the calendar section.
    var calendarFeed: (any CalendarTaskFeed)? { model.map { TasksCalendarFeed(model: $0) } }

    /// Puts the calendar behind the planner and mirrors today's and the next two weeks' slots.
    func attachCalendar(_ calendarHost: CalendarHost) async {
        guard let model, let calendarService = calendarHost.service else { return }
        let bridge = CalendarPlannerBridge(service: calendarService) { await MainActor.run { calendarHost.model?.slotCollectionID } }
        model.plannerMirror = bridge
        calendarHost.slotMoved = { [weak model] slotID, start, end in
            guard let model else { return }
            // The slot's own day, not the day the planner happens to show.
            let day = Calendar.current.startOfDay(for: start)
            let minutes = Int(start.timeIntervalSince(day) / 60)
            await model.moveSlot(id: slotID, day: day, start: minutes, end: minutes + Int(end.timeIntervalSince(start) / 60))
        }
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        for offset in 0..<15 {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            guard let slots = try? await service?.store.slots(for: day, calendar: calendar), !slots.isEmpty else { continue }
            let titles = Dictionary(
                slots.compactMap { slot in slot.taskID.flatMap { id in model.task(id: id).map { (id, $0.title) } } },
                uniquingKeysWith: { a, _ in a })
            await bridge.slotsChanged(day: day, slots: slots, titles: titles, calendar: calendar)
        }
        await model.loadPlanner()
    }
}

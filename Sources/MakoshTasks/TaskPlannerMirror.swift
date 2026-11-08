import Foundation

/// The calendar behind the day planner: own slots become calendar events there, and the
/// calendar's busy time comes back as read-only blocks. The app implements it.
public protocol TaskPlannerMirror: Sendable {
    func externalBlocks(day: Date, planID: UUID, calendar: Calendar) async -> [TaskPlanSlot]
    func slotsChanged(day: Date, slots: [TaskPlanSlot], titles: [UUID: String], calendar: Calendar) async
}

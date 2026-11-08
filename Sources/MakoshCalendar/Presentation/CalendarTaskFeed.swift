import Foundation

/// A task as the calendar's task column shows it; the Tasks section supplies them.
package struct CalendarTaskItem: Equatable, Identifiable, Sendable {
    package let id: UUID
    package let title: String
    package let estimateMinutes: Int?
    package let due: Date?
    package let overdue: Bool

    package init(id: UUID, title: String, estimateMinutes: Int?, due: Date?, overdue: Bool) {
        self.id = id
        self.title = title
        self.estimateMinutes = estimateMinutes
        self.due = due
        self.overdue = overdue
    }
}

package enum CalendarTaskAgenda: String, CaseIterable, Sendable {
    case today, week, overdue, all

    package var title: String {
        switch self {
        case .today: "Сегодня"
        case .week: "Неделя"
        case .overdue: "Просрочено"
        case .all: "Все"
        }
    }
}

/// The narrow link to the Tasks section: the app implements it, so neither module imports the other.
package protocol CalendarTaskFeed: Sendable {
    func tasks(agenda: CalendarTaskAgenda) async -> [CalendarTaskItem]
    func dueMarks(in interval: DateInterval) async -> [Date: [CalendarTaskItem]]
    func setEstimate(taskID: UUID, minutes: Int) async
}

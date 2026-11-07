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

    public init(
        id: UUID = UUID(), planID: UUID, taskID: UUID? = nil, title: String? = nil, start: Int, end: Int, kind: Kind,
        recurrence: Recurrence? = nil
    ) {
        self.id = id
        self.planID = planID
        self.taskID = taskID
        self.title = title
        self.start = start
        self.end = end
        self.kind = kind
        self.recurrence = recurrence
    }

    public var minutes: Int { max(0, end - start) }

    public static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]), (0...24).contains(hours), (0..<60).contains(minutes)
        else { return nil }
        return hours * 60 + minutes
    }
}

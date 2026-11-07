import Foundation

/// Time spent on a task. Once Jira confirmed the worklog the duration and
/// date are locked here; corrections happen in Jira and flow back by id.
public struct TaskTimeEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case timer, manual, meeting }
    public enum WorklogState: String, Codable, Sendable { case none, pending, confirmed, deletedInJira }

    public let id: UUID
    public let taskID: UUID
    public let source: Source
    public var startedAt: Date
    public var seconds: Int
    public var note: String
    public let meetingID: UUID?
    public var attemptID: UUID?
    public var worklogID: String?
    public var worklogState: WorklogState
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), taskID: UUID, source: Source, startedAt: Date, seconds: Int, note: String = "", meetingID: UUID? = nil,
        attemptID: UUID? = nil, worklogID: String? = nil, worklogState: WorklogState = .none, createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.source = source
        self.startedAt = startedAt
        self.seconds = seconds
        self.note = note
        self.meetingID = meetingID
        self.attemptID = attemptID
        self.worklogID = worklogID
        self.worklogState = worklogState
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var isLocked: Bool { worklogState == .confirmed }
}

/// The one running timer of the application.
public struct TaskTimer: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let startedAt: Date
    public var note: String
    public init(taskID: UUID, startedAt: Date, note: String = "") {
        self.taskID = taskID
        self.startedAt = startedAt
        self.note = note
    }
}

/// What the stop sheet shows before anything is written; `id` becomes the entry's id,
/// so confirming the same draft twice cannot create two entries.
public struct TaskTimeDraft: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let source: TaskTimeEntry.Source
    public var startedAt: Date
    public var seconds: Int
    public var note: String
    public let meetingID: UUID?
    public var sendToJira: Bool

    public init(
        id: UUID = UUID(), taskID: UUID, source: TaskTimeEntry.Source, startedAt: Date, seconds: Int, note: String = "", meetingID: UUID? = nil,
        sendToJira: Bool = false
    ) {
        self.id = id
        self.taskID = taskID
        self.source = source
        self.startedAt = startedAt
        self.seconds = seconds
        self.note = note
        self.meetingID = meetingID
        self.sendToJira = sendToJira
    }
}

extension TaskStore {
    public func timer() throws -> TaskTimer? {
        try query("SELECT data FROM \(t("tasks_timer")) WHERE id = 1").first.map { try decode(TaskTimer.self, $0[0]) }
    }

    public func saveTimer(_ timer: TaskTimer) throws {
        var value = timer
        value = TaskTimer(taskID: timer.taskID, startedAt: Self.millis(timer.startedAt), note: timer.note)
        try execute(
            "INSERT INTO \(t("tasks_timer"))(id, data) VALUES(1, $1::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data", [try encode(value)])
    }

    public func clearTimer() throws { try execute("DELETE FROM \(t("tasks_timer")) WHERE id = 1") }

    public func entries(taskID: UUID) throws -> [TaskTimeEntry] {
        try query("SELECT data FROM \(t("tasks_time_entries")) WHERE task_id = $1 ORDER BY started_at DESC", [taskID.uuidString]).map {
            try decode(TaskTimeEntry.self, $0[0])
        }
    }

    public func entry(id: UUID) throws -> TaskTimeEntry? {
        try query("SELECT data FROM \(t("tasks_time_entries")) WHERE id = $1", [id.uuidString]).first.map { try decode(TaskTimeEntry.self, $0[0]) }
    }

    /// Entries whose start lies in `[from, to)`.
    public func entries(from: Date, to: Date) throws -> [TaskTimeEntry] {
        try query(
            "SELECT data FROM \(t("tasks_time_entries")) WHERE started_at >= $1 AND started_at < $2 ORDER BY started_at", [Self.iso(from), Self.iso(to)]
        ).map { try decode(TaskTimeEntry.self, $0[0]) }
    }

    @discardableResult public func insertEntry(_ entry: TaskTimeEntry) throws -> TaskTimeEntry {
        var value = entry
        value.startedAt = Self.millis(entry.startedAt)
        value.updatedAt = Self.millis(entry.updatedAt)
        try execute(
            "INSERT INTO \(t("tasks_time_entries"))(id, task_id, started_at, seconds, data) VALUES($1, $2, $3, $4, $5::jsonb)",
            [value.id.uuidString, value.taskID.uuidString, Self.iso(value.startedAt), String(value.seconds), try encode(value)])
        return value
    }

    @discardableResult public func updateEntry(_ entry: TaskTimeEntry) throws -> TaskTimeEntry {
        var value = entry
        value.startedAt = Self.millis(entry.startedAt)
        value.updatedAt = Self.millis(entry.updatedAt)
        try execute(
            "UPDATE \(t("tasks_time_entries")) SET started_at = $2, seconds = $3, data = $4::jsonb WHERE id = $1",
            [value.id.uuidString, Self.iso(value.startedAt), String(value.seconds), try encode(value)])
        return value
    }

    public func deleteEntry(id: UUID) throws {
        guard let entry = try entry(id: id) else { throw TaskStoreError.notFound }
        guard !entry.isLocked else { throw TasksFailure.entryLocked }
        try execute("DELETE FROM \(t("tasks_time_entries")) WHERE id = $1", [id.uuidString])
    }
}

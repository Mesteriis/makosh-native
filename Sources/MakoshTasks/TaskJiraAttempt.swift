import Foundation
import MakoshJira

/// One explicit write to Jira and what became of it. An attempt whose
/// outcome is unknown stays unknown until a user resolves it; it is never
/// resent, because a worklog counted twice is worse than one missed.
public struct TaskJiraAttempt: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case transition, worklog, comment, fields, assignee }
    public enum State: String, Codable, Sendable { case queued, sent, unknown, confirmed, rejected }
    public enum Payload: Codable, Equatable, Sendable {
        case transition(id: String, toStatusID: String, fields: [String: JiraFieldValue])
        case worklog(started: Date, seconds: Int, comment: String?, entryID: UUID)
        case comment(text: String, adf: Data)
        case fields(JiraIssuePatch)
        case assignee(accountID: String?)
    }

    public let id: UUID
    public let taskID: UUID
    public let connectionID: UUID
    public let issueID: String
    public let kind: Kind
    public let payload: Payload
    public var state: State
    public let createdAt: Date
    public var updatedAt: Date
    public var resolvedAt: Date?
    public var resultID: String?
    public var reason: String?

    public init(
        id: UUID = UUID(), taskID: UUID, connectionID: UUID, issueID: String, kind: Kind, payload: Payload, state: State = .queued,
        createdAt: Date = Date(), updatedAt: Date? = nil, resolvedAt: Date? = nil, resultID: String? = nil, reason: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.connectionID = connectionID
        self.issueID = issueID
        self.kind = kind
        self.payload = payload
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.resolvedAt = resolvedAt
        self.resultID = resultID
        self.reason = reason
    }

    public var isOpen: Bool { state == .queued || state == .sent || state == .unknown }

    public func with(state: State, resultID: String? = nil, reason: String? = nil, at: Date = Date()) -> TaskJiraAttempt {
        var value = self
        value.state = state
        value.updatedAt = at
        if let resultID { value.resultID = resultID }
        if let reason { value.reason = reason }
        if state == .confirmed || state == .rejected { value.resolvedAt = at }
        return value
    }

    /// The only moves the store accepts.
    static func allows(_ from: State, _ to: State) -> Bool {
        switch (from, to) {
        case (.queued, .sent), (.sent, .confirmed), (.sent, .rejected), (.sent, .unknown), (.unknown, .confirmed), (.unknown, .rejected):
            return true
        default:
            return false
        }
    }

    public var title: String {
        switch kind {
        case .transition: "Переход"
        case .worklog: "Время"
        case .comment: "Комментарий"
        case .fields: "Правка"
        case .assignee: "Исполнитель"
        }
    }
}

extension TaskStore {
    public func attempts(taskID: UUID) throws -> [TaskJiraAttempt] {
        try query("SELECT data FROM \(t("tasks_jira_attempts")) WHERE task_id = $1 ORDER BY created_at", [taskID.uuidString]).map {
            try decode(TaskJiraAttempt.self, $0[0])
        }
    }

    public func attempt(id: UUID) throws -> TaskJiraAttempt? {
        try query("SELECT data FROM \(t("tasks_jira_attempts")) WHERE id = $1", [id.uuidString]).first.map {
            try decode(TaskJiraAttempt.self, $0[0])
        }
    }

    /// Every attempt still queued, sent or unknown, oldest first.
    public func openAttempts() throws -> [TaskJiraAttempt] {
        try query("SELECT data FROM \(t("tasks_jira_attempts")) WHERE state IN ('queued','sent','unknown') ORDER BY created_at").map {
            try decode(TaskJiraAttempt.self, $0[0])
        }
    }

    public func openAttempt(taskID: UUID, kind: TaskJiraAttempt.Kind) throws -> TaskJiraAttempt? {
        try query(
            "SELECT data FROM \(t("tasks_jira_attempts")) WHERE task_id = $1 AND kind = $2 AND state IN ('queued','sent','unknown') ORDER BY created_at LIMIT 1",
            [taskID.uuidString, kind.rawValue]
        ).first.map { try decode(TaskJiraAttempt.self, $0[0]) }
    }

    @discardableResult public func insertAttempt(_ attempt: TaskJiraAttempt) throws -> TaskJiraAttempt {
        var value = attempt
        value.state = .queued
        value.updatedAt = Self.millis(value.updatedAt)
        try execute(
            """
            INSERT INTO \(t("tasks_jira_attempts"))(id, task_id, connection_id, issue_id, kind, state, data, created_at, updated_at, resolved_at)
            VALUES($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $9, NULL)
            """,
            [
                value.id.uuidString, value.taskID.uuidString, value.connectionID.uuidString, value.issueID, value.kind.rawValue,
                value.state.rawValue,
                try encode(value), Self.iso(value.createdAt), Self.iso(value.updatedAt),
            ])
        return value
    }

    /// Moves an attempt along the allowed path; `expectedState` guards against a stale caller.
    @discardableResult public func updateAttempt(_ attempt: TaskJiraAttempt, expectedState: TaskJiraAttempt.State) throws -> TaskJiraAttempt
    {
        try transaction {
            guard let current = try self.attempt(id: attempt.id) else { throw TaskStoreError.notFound }
            guard current.state == expectedState, TaskJiraAttempt.allows(current.state, attempt.state) else {
                throw TaskStoreError.invalidTransition
            }
            var value = attempt
            value.updatedAt = Self.millis(value.updatedAt)
            value.resolvedAt = value.resolvedAt.map(Self.millis)
            try self.execute(
                "UPDATE \(self.t("tasks_jira_attempts")) SET state = $2, data = $3::jsonb, updated_at = $4, resolved_at = $5 WHERE id = $1",
                [
                    value.id.uuidString, value.state.rawValue, try self.encode(value), Self.iso(value.updatedAt),
                    value.resolvedAt.map(Self.iso),
                ])
            return value
        }
    }
}

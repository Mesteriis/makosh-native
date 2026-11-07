import Foundation
import MakoshJira

/// Timer, drafts and entries. One running timer; stopping it yields a
/// draft the user edits before anything is written; confirming writes the
/// entry and, when asked, one worklog attempt through the journal.
public actor TaskTimeService {
    private let store: TaskStore
    private let journal: TaskJiraAttemptJournal
    private let now: @Sendable () -> Date

    public init(store: TaskStore, journal: TaskJiraAttemptJournal, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.journal = journal
        self.now = now
    }

    public func timer() async throws -> TaskTimer? { try await store.timer() }

    /// Starts a timer on `taskID`; a timer on another task must be stopped first.
    public func start(taskID: UUID, note: String) async throws -> TaskTimer {
        if let running = try await store.timer(), running.taskID != taskID { throw TasksFailure.timerRunning(running.taskID) }
        let timer = TaskTimer(taskID: taskID, startedAt: TaskStore.millis(now()), note: note)
        try await store.saveTimer(timer)
        return timer
    }

    /// Stops the timer and returns the draft; the duration is rounded up to a whole minute.
    public func stop() async throws -> TaskTimeDraft {
        guard let timer = try await store.timer() else { throw TaskStoreError.notFound }
        try await store.clearTimer()
        let elapsed = max(0, now().timeIntervalSince(timer.startedAt))
        let seconds = Self.wholeMinutes(elapsed)
        return TaskTimeDraft(
            taskID: timer.taskID, source: .timer, startedAt: timer.startedAt, seconds: seconds, note: timer.note,
            sendToJira: try await suggestsWorklog(taskID: timer.taskID))
    }

    /// A cancelled timer draft puts the timer back with its original start; other drafts restore nothing.
    public func restore(_ draft: TaskTimeDraft) async throws {
        guard draft.source == .timer, try await store.timer() == nil else { return }
        try await store.saveTimer(TaskTimer(taskID: draft.taskID, startedAt: draft.startedAt, note: draft.note))
    }

    /// A draft for hand-entered or meeting time; `sendToJira` nil follows the connection's setting.
    public nonisolated func draft(
        manual taskID: UUID, startedAt: Date, seconds: Int, note: String, meetingID: UUID?, sendToJira: Bool,
        source: TaskTimeEntry.Source = .manual
    ) -> TaskTimeDraft {
        TaskTimeDraft(
            taskID: taskID, source: meetingID == nil ? source : .meeting, startedAt: startedAt,
            seconds: Self.wholeMinutes(TimeInterval(seconds)),
            note: note, meetingID: meetingID, sendToJira: sendToJira)
    }

    public func suggestsWorklog(taskID: UUID) async throws -> Bool {
        guard let task = try await store.task(id: taskID), let source = task.source,
            let connectionID = UUID(uuidString: source.identity.accountID)
        else { return false }
        return try await store.connections().first { $0.id == connectionID }?.suggestWorklog ?? false
    }

    /// Writes the entry (once per draft id) and submits the worklog when asked.
    public func confirm(_ draft: TaskTimeDraft) async throws -> TaskTimeEntry {
        guard draft.seconds > 0 else { throw JiraAdapterError.invalidRequest }
        var entry = TaskTimeEntry(
            id: draft.id, taskID: draft.taskID, source: draft.source, startedAt: draft.startedAt,
            seconds: Self.wholeMinutes(TimeInterval(draft.seconds)),
            note: draft.note, meetingID: draft.meetingID, createdAt: now())
        entry = try await store.insertEntry(entry)
        guard draft.sendToJira, let task = try await store.task(id: draft.taskID), let source = task.source,
            let connectionID = UUID(uuidString: source.identity.accountID)
        else { return entry }
        entry.worklogState = .pending
        entry.updatedAt = now()
        entry = try await store.updateEntry(entry)
        let attempt = await journal.submit(
            TaskJiraAttempt(
                taskID: task.id, connectionID: connectionID, issueID: source.identity.externalID, kind: .worklog,
                payload: .worklog(
                    started: entry.startedAt, seconds: entry.seconds, comment: entry.note.isEmpty ? nil : entry.note, entryID: entry.id),
                createdAt: now()))
        guard case .worklog(_, _, _, let boundEntryID) = attempt.payload, boundEntryID == entry.id else {
            // Another worklog of this task is still open; this entry stays local and unsent.
            entry.worklogState = .none
            entry.updatedAt = now()
            _ = try await store.updateEntry(entry)
            throw TasksFailure.attemptInFlight
        }
        entry.attemptID = attempt.id
        if attempt.state == .confirmed {
            entry.worklogID = attempt.resultID
            entry.worklogState = .confirmed
        } else if attempt.state == .rejected {
            entry.worklogState = .none
        }
        entry.updatedAt = now()
        return try await store.updateEntry(entry)
    }

    /// A settled attempt confirmed later (after `resolve`) is reflected on its entry.
    public func applyAttempt(_ attempt: TaskJiraAttempt) async throws {
        guard case .worklog(_, _, _, let entryID) = attempt.payload, var entry = try await store.entry(id: entryID) else { return }
        switch attempt.state {
        case .confirmed:
            entry.worklogID = attempt.resultID
            entry.worklogState = .confirmed
        case .rejected: entry.worklogState = .none
        default: return
        }
        entry.updatedAt = now()
        try await store.updateEntry(entry)
    }

    /// Note edits are always allowed; duration and start only until Jira confirmed the worklog.
    @discardableResult public func update(_ entry: TaskTimeEntry) async throws -> TaskTimeEntry {
        guard let current = try await store.entry(id: entry.id) else { throw TaskStoreError.notFound }
        var value = entry
        if current.isLocked {
            guard entry.seconds == current.seconds, TaskStore.millis(entry.startedAt) == current.startedAt else {
                throw TasksFailure.entryLocked
            }
            value.worklogID = current.worklogID
            value.worklogState = current.worklogState
            value.attemptID = current.attemptID
        } else {
            value.seconds = Self.wholeMinutes(TimeInterval(entry.seconds))
        }
        value.updatedAt = now()
        return try await store.updateEntry(value)
    }

    public func delete(entryID: UUID) async throws { try await store.deleteEntry(id: entryID) }

    /// Jira's current worklogs for the task: moved or resized ones update the entry, missing ones mark it.
    public func applyWorklogs(_ worklogs: [JiraWorklog], taskID: UUID) async throws {
        let byID = Dictionary(worklogs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for var entry in try await store.entries(taskID: taskID)
        where entry.worklogState == .confirmed || entry.worklogState == .deletedInJira {
            guard let worklogID = entry.worklogID else { continue }
            if let worklog = byID[worklogID] {
                entry.startedAt = worklog.started
                entry.seconds = worklog.seconds
                entry.worklogState = .confirmed
            } else {
                entry.worklogState = .deletedInJira
            }
            entry.updatedAt = now()
            try await store.updateEntry(entry)
        }
    }

    public func summary(day: Date, calendar: Calendar) async throws -> (daySeconds: Int, weekSeconds: Int) {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: day)?.start,
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)
        else { return (0, 0) }
        let week = try await store.entries(from: weekStart, to: weekEnd).filter { $0.worklogState != .deletedInJira }
        let today = week.filter { $0.startedAt >= start && $0.startedAt < end }
        return (today.reduce(0) { $0 + $1.seconds }, week.reduce(0) { $0 + $1.seconds })
    }

    static func wholeMinutes(_ seconds: TimeInterval) -> Int { max(60, Int((seconds / 60).rounded(.up)) * 60) }
}

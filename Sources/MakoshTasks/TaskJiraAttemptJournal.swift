import Foundation
import MakoshJira

/// Sends attempts once and settles their outcomes. One open attempt per
/// (task, kind) at a time; an unknown outcome waits for `resolve` or
/// `dismiss`, never for a retry.
public actor TaskJiraAttemptJournal {
    public typealias AdapterLookup = @Sendable (UUID) async -> (any JiraAdapter)?
    private let store: TaskStore
    private var adapter: AdapterLookup
    private let now: @Sendable () -> Date
    public private(set) var lastFailure: String?

    public init(store: TaskStore, now: @escaping @Sendable () -> Date = Date.init, adapter: @escaping AdapterLookup) {
        self.store = store
        self.adapter = adapter
        self.now = now
    }

    func replaceAdapterLookup(_ lookup: @escaping AdapterLookup) { adapter = lookup }

    /// Records the attempt, sends it and returns its settled (or unknown) state.
    /// An attempt of the same kind still open on the task is returned instead.
    public func submit(_ attempt: TaskJiraAttempt) async -> TaskJiraAttempt {
        do {
            if let open = try await store.openAttempt(taskID: attempt.taskID, kind: attempt.kind) {
                var value = open
                value.reason = "уже выполняется"
                return value
            }
            var value = try await store.insertAttempt(attempt)
            guard let adapter = await adapter(attempt.connectionID) else {
                value = try await store.updateAttempt(value.with(state: .sent, at: now()), expectedState: .queued)
                return try await store.updateAttempt(
                    value.with(state: .rejected, reason: "подключение удалено", at: now()), expectedState: .sent)
            }
            value = try await store.updateAttempt(value.with(state: .sent, at: now()), expectedState: .queued)
            do {
                let resultID = try await perform(value, adapter: adapter)
                return try await store.updateAttempt(value.with(state: .confirmed, resultID: resultID, at: now()), expectedState: .sent)
            } catch let error as JiraAdapterError {
                let outcome = Self.outcome(of: error)
                return try await store.updateAttempt(
                    value.with(state: outcome, reason: JiraDiagnostics.code(error), at: now()), expectedState: .sent)
            } catch {
                return try await store.updateAttempt(
                    value.with(state: .unknown, reason: JiraDiagnostics.code(error), at: now()), expectedState: .sent)
            }
        } catch {
            lastFailure = "Журнал попыток недоступен."
            var value = attempt
            value.state = .unknown
            value.reason = "журнал"
            return value
        }
    }

    /// Attempts that were in flight when the process died cannot be trusted either way.
    public func resume() async {
        do {
            for attempt in try await store.openAttempts() where attempt.state == .sent {
                _ = try await store.updateAttempt(attempt.with(state: .unknown, reason: "перезапуск", at: now()), expectedState: .sent)
            }
        } catch {
            lastFailure = "Журнал попыток недоступен."
        }
    }

    /// Reads Jira again and settles an unknown attempt when exactly one match exists.
    public func resolve(_ id: UUID) async -> TaskJiraAttempt {
        do {
            guard let attempt = try await store.attempt(id: id) else { throw TaskStoreError.notFound }
            guard attempt.state == .unknown else { return attempt }
            guard let adapter = await adapter(attempt.connectionID) else {
                return try await store.updateAttempt(
                    attempt.with(state: .rejected, reason: "подключение удалено", at: now()), expectedState: .unknown)
            }
            let matches = try await matches(for: attempt, adapter: adapter)
            switch matches.count {
            case 1:
                return try await store.updateAttempt(
                    attempt.with(state: .confirmed, resultID: matches[0], at: now()), expectedState: .unknown)
            case 0:
                return try await store.updateAttempt(
                    attempt.with(state: .rejected, reason: "не найдено", at: now()), expectedState: .unknown)
            default:
                var value = attempt
                value.reason = "несколько совпадений"
                return value
            }
        } catch {
            guard var attempt = try? await store.attempt(id: id) else {
                return TaskJiraAttempt(
                    taskID: UUID(), connectionID: UUID(), issueID: "", kind: .comment, payload: .comment(text: "", adf: Data()),
                    state: .unknown)
            }
            attempt.reason = "проверка не удалась: " + JiraDiagnostics.code(error)
            return attempt
        }
    }

    public func dismiss(_ id: UUID) async -> TaskJiraAttempt? {
        guard let attempt = try? await store.attempt(id: id), attempt.state == .unknown else { return nil }
        return try? await store.updateAttempt(
            attempt.with(state: .rejected, reason: "отказ пользователя", at: now()), expectedState: .unknown)
    }

    // MARK: Internals

    private func perform(_ attempt: TaskJiraAttempt, adapter: any JiraAdapter) async throws -> String? {
        switch attempt.payload {
        case .transition(let id, _, let fields):
            try await adapter.transition(issueID: attempt.issueID, transitionID: id, fields: fields)
            return nil
        case .worklog(let started, let seconds, let comment, _):
            return try await adapter.addWorklog(issueID: attempt.issueID, started: started, seconds: seconds, comment: comment)
        case .comment(_, let adf):
            return try await adapter.addComment(issueID: attempt.issueID, body: adf)
        case .fields(let patch):
            try await adapter.updateFields(issueID: attempt.issueID, patch: patch)
            return nil
        case .assignee(let accountID):
            try await adapter.assign(issueID: attempt.issueID, accountID: accountID)
            return nil
        }
    }

    /// A definite refusal is rejected; anything that may have reached Jira is unknown.
    static func outcome(of error: JiraAdapterError) -> TaskJiraAttempt.State {
        switch error {
        case .invalidRequest, .unauthorized, .notFound, .unsupportedFields, .descriptionNotEditable, .invalidCursor: return .rejected
        case .http(let status): return (400..<500).contains(status) && status != 408 && status != 409 ? .rejected : .unknown
        case .rateLimited: return .rejected
        case .transport, .invalidResponse: return .unknown
        }
    }

    private func matches(for attempt: TaskJiraAttempt, adapter: any JiraAdapter) async throws -> [String] {
        let me = try await adapter.currentUser()
        switch attempt.payload {
        case .worklog(let started, let seconds, let comment, _):
            return try await adapter.worklogs(issueID: attempt.issueID).filter { worklog in
                worklog.author.accountID == me.accountID && abs(worklog.started.timeIntervalSince(started)) <= 1
                    && worklog.seconds == seconds
                    && worklog.commentText.trimmingCharacters(in: .whitespacesAndNewlines)
                        == (comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }.map(\.id)
        case .comment(let text, _):
            let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var page = try await adapter.comments(issueID: attempt.issueID, nextToken: nil)
            var found = page.items.filter {
                $0.author.accountID == me.accountID && $0.bodyText.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
            }
            var pages = 0
            while let next = page.nextToken, pages < 20 {
                pages += 1
                page = try await adapter.comments(issueID: attempt.issueID, nextToken: next)
                found += page.items.filter {
                    $0.author.accountID == me.accountID && $0.bodyText.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
                }
            }
            return found.map(\.id)
        case .transition(_, let toStatusID, _):
            let issue = try await adapter.issue(id: attempt.issueID)
            return issue.status.id == toStatusID ? [issue.status.id] : []
        case .fields(let patch):
            let issue = try await adapter.issue(id: attempt.issueID)
            var same = true
            if let summary = patch.summary { same = same && issue.summary == summary }
            if let labels = patch.labels { same = same && issue.labels == labels }
            if let priorityID = patch.priorityID { same = same && issue.priority?.id == priorityID }
            if let due = patch.due { same = same && issue.due.map(JiraDateDay.string) == due.map(JiraDateDay.string) }
            if let description = patch.descriptionADF { same = same && issue.descriptionText == JiraADF.text(from: description) }
            return same ? [issue.id] : []
        case .assignee(let accountID):
            let issue = try await adapter.issue(id: attempt.issueID)
            return issue.assignee?.accountID == accountID ? [issue.id] : []
        }
    }
}

enum JiraDateDay {
    static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

import Foundation
import MakoshCore
import MakoshJira

public struct JiraMirrorResult: Equatable, Sendable {
    public var applied = 0
    public var left = 0
    public var mentionsUnavailable = false
    public var deferredUntil: Date?
    public var failure: String?
    public init() {}
}

/// Pulls the issues assigned to the user (and those mentioning them) into
/// the store as provider observations. The local layer is never touched
/// except for one rule: a Jira status in the Done category completes the
/// local task when it is still open.
public actor JiraMirror {
    public static let pageSize = 50
    public static let backoffFloor: TimeInterval = 5
    public static let backoffCeiling: TimeInterval = 3600
    public static let incrementalOverlap: TimeInterval = 600

    private let store: TaskStore
    public let connectionID: UUID
    private let adapter: any JiraAdapter
    private let accountID: String
    private var mentions: Bool
    private let now: @Sendable () -> Date
    private var lastSuccessfulSync: Date?
    private var deferredUntil: Date?
    private var failures = 0
    public private(set) var mentionsUnavailable = false

    public init(
        store: TaskStore, connectionID: UUID, adapter: any JiraAdapter, accountID: String, mentions: Bool,
        lastSuccessfulSync: Date? = nil, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.connectionID = connectionID
        self.adapter = adapter
        self.accountID = accountID
        self.mentions = mentions
        self.lastSuccessfulSync = lastSuccessfulSync
        self.now = now
    }

    public var lastSync: Date? { lastSuccessfulSync }

    /// One pass: every page of the selection applied as it arrives. A full
    /// pass also demotes issues that no longer come back.
    public func sync(full: Bool) async -> JiraMirrorResult {
        var result = JiraMirrorResult()
        result.mentionsUnavailable = mentionsUnavailable
        let start = now()
        if let deferredUntil, start < deferredUntil {
            result.deferredUntil = deferredUntil
            result.failure = "Отложено после ошибки Jira."
            return result
        }
        var seen: Set<String> = []
        var token: String?
        var cursorResets = 0
        var includeMentions = mentions && !mentionsUnavailable
        var applyFailed = false
        while true {
            let page: JiraPage<JiraIssue>
            do {
                page = try await adapter.searchIssues(
                    jql: jql(full: full, mentions: includeMentions), nextToken: token, limit: Self.pageSize)
            } catch JiraAdapterError.http(let status) where status == 400 && includeMentions {
                // Jira refused the mention clause; carry on with assignments only.
                includeMentions = false
                mentionsUnavailable = true
                result.mentionsUnavailable = true
                token = nil
                continue
            } catch JiraAdapterError.invalidCursor where cursorResets == 0 && token != nil {
                cursorResets += 1
                token = nil
                continue
            } catch let error as JiraAdapterError {
                return postpone(result, error: error, at: start)
            } catch {
                return postpone(result, error: .transport(code: "cancelled"), at: start)
            }
            for issue in page.items {
                do {
                    try await apply(issue)
                    seen.insert(issue.id)
                    result.applied += 1
                } catch {
                    applyFailed = true
                    result.failure = "Не удалось сохранить задачу."
                }
            }
            guard let next = page.nextToken else { break }
            token = next
        }
        if full, !applyFailed {
            do { result.left = try await demote(notIn: seen) } catch { result.failure = "Не удалось обновить ушедшие задачи." }
        }
        failures = 0
        deferredUntil = nil
        // A pass that could not store something is not a success: the window stays put.
        if !applyFailed { lastSuccessfulSync = start }
        return result
    }

    /// Rereads one issue with its transitions, comments and worklogs and records the observation.
    public func refresh(issueID: String) async throws -> TaskProviderObservation {
        let issue = try await adapter.issue(id: issueID)
        async let transitions = adapter.transitions(issueID: issueID)
        async let comments = adapter.comments(issueID: issueID, nextToken: nil)
        async let worklogs = adapter.worklogs(issueID: issueID)
        let me = accountID
        let observation = TaskProviderObservation(
            identity: identity(issue), observedAt: now(), raw: (try? JSONEncoder().encode(issue)) ?? Data(), issue: issue,
            comments: try await comments.items, myWorklogs: try await worklogs.filter { $0.author.accountID == me },
            transitions: try await transitions)
        try await apply(issue, observation: observation)
        return observation
    }

    // MARK: Internals

    func jql(full: Bool, mentions: Bool) -> String {
        var selection = "assignee = currentUser()"
        if mentions { selection = "(\(selection) OR comment ~ \"\(accountID)\")" }
        var clauses = [selection]
        if !full, let last = lastSuccessfulSync {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            clauses.append("updated >= \"\(formatter.string(from: last.addingTimeInterval(-Self.incrementalOverlap)))\"")
        }
        return clauses.joined(separator: " AND ") + " ORDER BY updated ASC"
    }

    private func identity(_ issue: JiraIssue) -> ServiceIdentity {
        ServiceIdentity(service: "jira", accountID: connectionID.uuidString, externalID: issue.id)
    }

    private func postpone(_ result: JiraMirrorResult, error: JiraAdapterError, at start: Date) -> JiraMirrorResult {
        var value = result
        failures += 1
        let backoff = min(Self.backoffCeiling, Self.backoffFloor * pow(2, Double(failures - 1)))
        let wait: TimeInterval
        if case .rateLimited(let retryAfter) = error, let retryAfter { wait = max(retryAfter, Self.backoffFloor) } else { wait = backoff }
        deferredUntil = start.addingTimeInterval(wait)
        value.deferredUntil = deferredUntil
        value.failure = "Jira: " + JiraDiagnostics.code(error)
        return value
    }

    private func apply(_ issue: JiraIssue, observation: TaskProviderObservation? = nil) async throws {
        let identity = identity(issue)
        let membership: TaskMembership = issue.assignee?.accountID == accountID ? .assigned : .mentioned
        let observation =
            observation
            ?? TaskProviderObservation(
                identity: identity, observedAt: now(), raw: (try? JSONEncoder().encode(issue)) ?? Data(), issue: issue)
        if let existing = try await store.task(source: identity) {
            let previous = try await store.latestObservation(taskID: existing.id)
            var task = existing
            // Title and link follow Jira while the user has not edited them.
            if let previous, task.title == previous.issue.summary { task.title = issue.summary }
            if let previous, task.url == previous.issue.browseURL || task.url == nil { task.url = issue.browseURL }
            task.source = TaskSource(identity: identity, membership: membership)
            if issue.status.category == .done, task.status != .done, task.status != .cancelled {
                task = try TaskDomain.applying(status: .done, to: task, now: now()) { _ in nil }
            }
            if task != existing { try await store.update(task, expectedRevision: existing.revision, actor: .provider) }
            try await store.saveObservation(observation, for: existing.id)
        } else {
            var task = Task(
                title: issue.summary, status: .inbox, priority: 4, url: issue.browseURL,
                source: TaskSource(identity: identity, membership: membership),
                createdAt: now())
            if issue.status.category == .done { task = try TaskDomain.applying(status: .done, to: task, now: now()) { _ in nil } }
            let inserted = try await store.insert(task, actor: .provider)
            try await store.saveObservation(observation, for: inserted.id)
        }
    }

    /// Issues of this connection that the full selection no longer returns.
    private func demote(notIn seen: Set<String>) async throws -> Int {
        var count = 0
        for (taskID, source) in try await store.sources(connectionID: connectionID) where !seen.contains(source.identity.externalID) {
            guard source.membership == .assigned || source.membership == .mentioned else { continue }
            let active = try await store.hasLocalActivity(taskID: taskID)
            try await store.setMembership(taskID: taskID, active ? .kept : .none)
            count += 1
        }
        return count
    }
}

extension TaskStore {
    /// Something the user is in the middle of: active status, a running timer,
    /// time not yet in Jira, or an attempt still in flight.
    public func hasLocalActivity(taskID: UUID) throws -> Bool {
        if let task = try task(id: taskID), task.status == .active { return true }
        if try openAttempt(taskID: taskID, kind: .worklog) != nil || !(try openAttempts().filter { $0.taskID == taskID }.isEmpty) {
            return true
        }
        let timer = try query("SELECT 1 FROM \(t("tasks_timer")) WHERE data->>'taskID' = $1", [taskID.uuidString])
        if !timer.isEmpty { return true }
        let unsent = try query(
            "SELECT 1 FROM \(t("tasks_time_entries")) WHERE task_id = $1 AND COALESCE(data->>'worklogState', 'none') IN ('none', 'pending') LIMIT 1",
            [taskID.uuidString])
        return !unsent.isEmpty
    }
}

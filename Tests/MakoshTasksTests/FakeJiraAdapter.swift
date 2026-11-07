import Foundation
import MakoshJira

/// A scriptable Jira: issues, transitions, comments and worklogs in memory,
/// every call recorded, any call made to fail or hang once.
final class FakeJiraAdapter: JiraAdapter, @unchecked Sendable {
    enum Call: Equatable { case currentUser, search(String), issue(String), transitions(String), comments(String), worklogs(String), projectStatuses(String), priorities, assignable(String), addWorklog(String, Int), addComment(String), transition(String, String), updateFields(String), assign(String, String?) }
    private let lock = NSLock()
    var me = JiraUser(accountID: "me-1", displayName: "Я")
    var issues: [String: JiraIssue] = [:]
    var transitionsByIssue: [String: [JiraTransition]] = [:]
    var commentsByIssue: [String: [JiraComment]] = [:]
    var worklogsByIssue: [String: [JiraWorklog]] = [:]
    var statusesByProject: [String: [JiraStatus]] = [:]
    var priorityList: [JiraPriority] = [JiraPriority(id: "1", name: "Highest"), JiraPriority(id: "3", name: "Medium")]
    var assignable: [JiraUser] = []
    /// Pages for `searchIssues`, consumed in order; each entry is (issues, nextToken).
    var searchPages: [([JiraIssue], String?)] = []
    /// Errors to throw on the next write of each kind; consumed once.
    var failNextWrite: JiraAdapterError?
    /// Errors to throw on the next search page; consumed once.
    var failNextSearch: JiraAdapterError?
    /// Rejects JQL containing this text with .http(400) — Jira refusing an operator.
    var rejectJQLContaining: String?
    private(set) var calls: [Call] = []
    private(set) var jqls: [String] = []
    private var nextID = 100

    private func record(_ call: Call) { lock.withLock { calls.append(call) } }
    private func takeWriteFailure() throws {
        let failure: JiraAdapterError? = lock.withLock {
            defer { failNextWrite = nil }
            return failNextWrite
        }
        if let failure { throw failure }
    }
    private func newID(_ prefix: String) -> String {
        lock.withLock {
            nextID += 1
            return "\(prefix)\(nextID)"
        }
    }

    func currentUser() async throws -> JiraUser {
        record(.currentUser)
        return me
    }
    func searchIssues(jql: String, nextToken: String?, limit: Int) async throws -> JiraPage<JiraIssue> {
        record(.search(jql))
        lock.withLock { jqls.append(jql) }
        if let reject = rejectJQLContaining, jql.contains(reject) { throw JiraAdapterError.http(status: 400) }
        let failure: JiraAdapterError? = lock.withLock {
            defer { failNextSearch = nil }
            return failNextSearch
        }
        if let failure { throw failure }
        let page: ([JiraIssue], String?)? = lock.withLock {
            guard !searchPages.isEmpty else { return nil }
            return searchPages.removeFirst()
        }
        guard let page else { return JiraPage(items: Array(issues.values.sorted { $0.key < $1.key }), nextToken: nil) }
        return JiraPage(items: page.0, nextToken: page.1)
    }
    func issue(id: String) async throws -> JiraIssue {
        record(.issue(id))
        guard let issue = issues[id] else { throw JiraAdapterError.notFound }
        return issue
    }
    func transitions(issueID: String) async throws -> [JiraTransition] {
        record(.transitions(issueID))
        return transitionsByIssue[issueID] ?? []
    }
    func comments(issueID: String, nextToken: String?) async throws -> JiraPage<JiraComment> {
        record(.comments(issueID))
        return JiraPage(items: commentsByIssue[issueID] ?? [], nextToken: nil)
    }
    func worklogs(issueID: String) async throws -> [JiraWorklog] {
        record(.worklogs(issueID))
        return worklogsByIssue[issueID] ?? []
    }
    func projectStatuses(projectKey: String) async throws -> [JiraStatus] {
        record(.projectStatuses(projectKey))
        return statusesByProject[projectKey] ?? []
    }
    func priorities() async throws -> [JiraPriority] {
        record(.priorities)
        return priorityList
    }
    func assignableUsers(projectKey: String, query: String) async throws -> [JiraUser] {
        record(.assignable(query))
        return assignable.filter { query.isEmpty || $0.displayName.lowercased().contains(query.lowercased()) }
    }
    func addWorklog(issueID: String, started: Date, seconds: Int, comment: String?) async throws -> String {
        record(.addWorklog(issueID, seconds))
        try takeWriteFailure()
        let id = newID("w")
        lock.withLock {
            worklogsByIssue[issueID, default: []].append(JiraWorklog(id: id, author: me, started: started, seconds: seconds, commentText: comment ?? ""))
        }
        return id
    }
    func addComment(issueID: String, body: Data) async throws -> String {
        record(.addComment(issueID))
        try takeWriteFailure()
        let id = newID("c")
        let now = Date()
        lock.withLock {
            commentsByIssue[issueID, default: []].append(
                JiraComment(id: id, author: me, created: now, updated: now, bodyADF: body, bodyText: JiraADF.text(from: body)))
        }
        return id
    }
    func transition(issueID: String, transitionID: String, fields: [String: JiraFieldValue]) async throws {
        record(.transition(issueID, transitionID))
        try takeWriteFailure()
        guard var issue = issues[issueID], let transition = (transitionsByIssue[issueID] ?? []).first(where: { $0.id == transitionID }) else {
            throw JiraAdapterError.notFound
        }
        issue.status = transition.to
        lock.withLock { issues[issueID] = issue }
    }
    func updateFields(issueID: String, patch: JiraIssuePatch) async throws {
        record(.updateFields(issueID))
        try takeWriteFailure()
        guard var issue = issues[issueID] else { throw JiraAdapterError.notFound }
        if let summary = patch.summary { issue.summary = summary }
        if let labels = patch.labels { issue.labels = labels }
        if let due = patch.due { issue.due = due }
        if let priorityID = patch.priorityID { issue.priority = priorityList.first { $0.id == priorityID } }
        if let description = patch.descriptionADF {
            issue.descriptionADF = description
            issue.descriptionText = JiraADF.text(from: description)
        }
        lock.withLock { issues[issueID] = issue }
    }
    func assign(issueID: String, accountID: String?) async throws {
        record(.assign(issueID, accountID))
        try takeWriteFailure()
        guard var issue = issues[issueID] else { throw JiraAdapterError.notFound }
        issue.assignee = accountID.map { id in assignable.first { $0.accountID == id } ?? JiraUser(accountID: id, displayName: id) }
        lock.withLock { issues[issueID] = issue }
    }

    // MARK: Fixtures

    static func issue(
        id: String, key: String, project: String = "QA", summary: String = "Задача", status: JiraStatus = toDo, assignee: JiraUser? = nil,
        updated: Date = Date(), description: Data? = nil
    ) -> JiraIssue {
        JiraIssue(
            id: id, key: key, projectKey: project, summary: summary, descriptionADF: description,
            descriptionText: description.map(JiraADF.text(from:)) ?? "", status: status, assignee: assignee, updated: updated,
            browseURL: URL(string: "https://jira.test/browse/\(key)")!)
    }
    static let toDo = JiraStatus(id: "1", name: "To Do", category: .new)
    static let inProgress = JiraStatus(id: "2", name: "In Progress", category: .indeterminate)
    static let done = JiraStatus(id: "3", name: "Done", category: .done)
    static let start = JiraTransition(id: "11", name: "Start", to: inProgress)
    static let finish = JiraTransition(
        id: "31", name: "Done", to: done,
        fields: [
            JiraField(
                key: "resolution", name: "Resolution", required: true, schemaType: "resolution",
                allowedValues: [JiraFieldOption(id: "10000", name: "Done")])
        ])
}

import Foundation

/// Every failure the section can show. No case carries remote text, URLs,
/// Foundation descriptions or credential values.
public enum JiraAdapterError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case unauthorized
    case notFound
    case invalidCursor
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case transport(code: String)
    case unsupportedFields([String])
    case descriptionNotEditable
}

/// What a provider must answer; Cloud implements it now, Data Center later.
public protocol JiraAdapter: Sendable {
    func currentUser() async throws -> JiraUser
    func searchIssues(jql: String, nextToken: String?, limit: Int) async throws -> JiraPage<JiraIssue>
    func issue(id: String) async throws -> JiraIssue
    func transitions(issueID: String) async throws -> [JiraTransition]
    func comments(issueID: String, nextToken: String?) async throws -> JiraPage<JiraComment>
    func worklogs(issueID: String) async throws -> [JiraWorklog]
    func projectStatuses(projectKey: String) async throws -> [JiraStatus]
    func priorities() async throws -> [JiraPriority]
    func assignableUsers(projectKey: String, query: String) async throws -> [JiraUser]

    /// Writes. Each is one request, never retried by the adapter; the
    /// caller's journal owns the attempt and its unknown outcomes.
    func addWorklog(issueID: String, started: Date, seconds: Int, comment: String?) async throws -> String
    func addComment(issueID: String, body: Data) async throws -> String
    func transition(issueID: String, transitionID: String, fields: [String: JiraFieldValue]) async throws
    func updateFields(issueID: String, patch: JiraIssuePatch) async throws
    func assign(issueID: String, accountID: String?) async throws
}

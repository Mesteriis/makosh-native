import Foundation

/// Jira Cloud over REST v3 with an email and API token.
public struct JiraCloudAdapter: JiraAdapter {
    let client: JiraRESTClient

    public init(credential: JiraCredential, sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        client = JiraRESTClient(transport: JiraTransport(credential: credential, sessionConfiguration: sessionConfiguration))
    }

    public func currentUser() async throws -> JiraUser { try await client.currentUser() }
    public func searchIssues(jql: String, nextToken: String?, limit: Int) async throws -> JiraPage<JiraIssue> {
        try await client.searchIssues(jql: jql, nextToken: nextToken, limit: limit)
    }
    public func issue(id: String) async throws -> JiraIssue { try await client.issue(id: id) }
    public func transitions(issueID: String) async throws -> [JiraTransition] { try await client.transitions(issueID: issueID) }
    public func comments(issueID: String, nextToken: String?) async throws -> JiraPage<JiraComment> {
        try await client.comments(issueID: issueID, nextToken: nextToken)
    }
    public func worklogs(issueID: String) async throws -> [JiraWorklog] { try await client.worklogs(issueID: issueID) }
    public func projectStatuses(projectKey: String) async throws -> [JiraStatus] { try await client.projectStatuses(projectKey: projectKey) }
    public func priorities() async throws -> [JiraPriority] { try await client.priorities() }
    public func assignableUsers(projectKey: String, query: String) async throws -> [JiraUser] {
        try await client.assignableUsers(projectKey: projectKey, query: query)
    }

    public func addWorklog(issueID: String, started: Date, seconds: Int, comment: String?) async throws -> String {
        try await client.addWorklog(issueID: issueID, started: started, seconds: seconds, comment: comment)
    }
    public func addComment(issueID: String, body: Data) async throws -> String { try await client.addComment(issueID: issueID, body: body) }
    public func transition(issueID: String, transitionID: String, fields: [String: JiraFieldValue]) async throws {
        try await client.transition(issueID: issueID, transitionID: transitionID, fields: fields)
    }
    public func updateFields(issueID: String, patch: JiraIssuePatch) async throws { try await client.updateFields(issueID: issueID, patch: patch) }
    public func assign(issueID: String, accountID: String?) async throws { try await client.assign(issueID: issueID, accountID: accountID) }
}

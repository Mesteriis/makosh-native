import Foundation
import XCTest
@testable import MakoshJira

final class JiraCloudAdapterReadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        JiraStubProtocol.reset([])
    }
    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }

    func testCurrentUserDecodes() async throws {
        JiraStubProtocol.reset([.json(JiraFixtures.me)])
        let me = try await JiraTestSupport.adapter().currentUser()
        XCTAssertEqual(me, JiraUser(accountID: "me-1", displayName: "Я"))
        XCTAssertEqual(JiraStubProtocol.recorded.first?.url?.path, "/rest/api/3/myself")
    }

    func testSearchDecodesIssuesAndNextToken() async throws {
        JiraStubProtocol.reset([.json(JiraFixtures.search)])
        let page = try await JiraTestSupport.adapter().searchIssues(jql: "assignee = currentUser()", nextToken: "tok-1", limit: 50)
        XCTAssertEqual(page.nextToken, "tok-2")
        XCTAssertEqual(page.items.map(\.key), ["QA-1", "QA-2"])
        let first = page.items[0]
        XCTAssertEqual(first.id, "10001")
        XCTAssertEqual(first.projectKey, "QA")
        XCTAssertEqual(first.status, JiraStatus(id: "1", name: "To Do", category: .new))
        XCTAssertEqual(first.priority, JiraPriority(id: "2", name: "High"))
        XCTAssertEqual(first.assignee, JiraUser(accountID: "me-1", displayName: "Я"))
        XCTAssertEqual(first.labels, ["billing"])
        XCTAssertEqual(first.issueType, "Task")
        XCTAssertEqual(first.updated, utc("2026-11-07T07:00:00.000Z"))
        XCTAssertEqual(first.browseURL, URL(string: "https://jira.test/browse/QA-1"))
        XCTAssertNotNil(first.due)
        let second = page.items[1]
        XCTAssertNil(second.priority)
        XCTAssertNil(second.assignee)
        XCTAssertNil(second.descriptionADF)
        XCTAssertEqual(second.descriptionText, "")
        XCTAssertEqual(second.status.category, .done)
        let body = try XCTUnwrap(JiraStubProtocol.body(at: 0))
        XCTAssertEqual(body["jql"] as? String, "assignee = currentUser()")
        XCTAssertEqual(body["nextPageToken"] as? String, "tok-1")
        XCTAssertEqual(body["maxResults"] as? Int, 50)
        XCTAssertEqual(JiraStubProtocol.recorded.first?.httpMethod, "POST")
    }

    func testIssueDescriptionTextIsProjected() async throws {
        JiraStubProtocol.reset([.json(JiraFixtures.search)])
        let page = try await JiraTestSupport.adapter().searchIssues(jql: "x", nextToken: nil, limit: 10)
        XCTAssertEqual(page.items[0].descriptionText, "Строка один\nстрока два\n\nАбзац два")
        XCTAssertNotNil(page.items[0].descriptionADF)
        JiraStubProtocol.reset([.json(JiraFixtures.issue)])
        let issue = try await JiraTestSupport.adapter().issue(id: "10001")
        XCTAssertEqual(issue.descriptionText, "Привет @Я")
        XCTAssertEqual(issue.status.name, "In Progress")
        XCTAssertEqual(JiraStubProtocol.recorded.first?.url?.path, "/rest/api/3/issue/10001")
    }

    func testTransitionsIncludeRequiredFields() async throws {
        JiraStubProtocol.reset([.json(JiraFixtures.transitions)])
        let transitions = try await JiraTestSupport.adapter().transitions(issueID: "10001")
        XCTAssertEqual(transitions.map(\.id), ["11", "31"])
        XCTAssertEqual(transitions[0].fields, [])
        let done = transitions[1]
        XCTAssertEqual(done.to, JiraStatus(id: "3", name: "Done", category: .done))
        let resolution = try XCTUnwrap(done.fields.first { $0.key == "resolution" })
        XCTAssertTrue(resolution.required)
        XCTAssertEqual(resolution.schemaType, "resolution")
        XCTAssertEqual(resolution.allowedValues?.map(\.name), ["Done", "Won't Do"])
        let note = try XCTUnwrap(done.fields.first { $0.key == "customfield_1" })
        XCTAssertFalse(note.required)
        XCTAssertEqual(note.schemaType, "string")
        let url = try XCTUnwrap(JiraStubProtocol.recorded.first?.url)
        XCTAssertEqual(url.path, "/rest/api/3/issue/10001/transitions")
        XCTAssertTrue(url.query?.contains("expand=transitions.fields") == true)
    }

    func testCommentsPageDecodes() async throws {
        JiraStubProtocol.reset([.json(JiraFixtures.comments)])
        let page = try await JiraTestSupport.adapter().comments(issueID: "10001", nextToken: nil)
        XCTAssertEqual(page.items.map(\.id), ["c1", "c2"])
        XCTAssertEqual(page.items[0].bodyText, "Посмотри, пожалуйста")
        XCTAssertEqual(page.items[1].author.accountID, "me-1")
        XCTAssertEqual(page.items[1].updated, utc("2026-11-07T09:05:00.000Z"))
        XCTAssertNil(page.nextToken, "two of two means the last page")
    }

    func testWorklogsDecodeStartedWithOffset() async throws {
        JiraStubProtocol.reset([.json(JiraFixtures.worklogs)])
        let worklogs = try await JiraTestSupport.adapter().worklogs(issueID: "10001")
        XCTAssertEqual(worklogs.count, 1)
        XCTAssertEqual(worklogs[0].id, "w1")
        XCTAssertEqual(worklogs[0].seconds, 1800)
        XCTAssertEqual(worklogs[0].started, utc("2026-11-07T06:00:00.000Z"))
        XCTAssertEqual(worklogs[0].commentText, "созвон")
        XCTAssertEqual(worklogs[0].author.accountID, "me-1")
    }

    func testProjectStatusesDecode() async throws {
        JiraStubProtocol.reset([.json(JiraFixtures.projectStatuses)])
        let statuses = try await JiraTestSupport.adapter().projectStatuses(projectKey: "QA")
        XCTAssertEqual(statuses.map(\.name), ["To Do", "In Progress", "Done"], "unique, in first-seen order")
        XCTAssertEqual(JiraStubProtocol.recorded.first?.url?.path, "/rest/api/3/project/QA/statuses")
        JiraStubProtocol.reset([.json(JiraFixtures.priorities)])
        let priorities = try await JiraTestSupport.adapter().priorities()
        XCTAssertEqual(priorities.map(\.name), ["Highest", "High", "Medium"])
    }

    func testAssignableUsersQueryIsSent() async throws {
        JiraStubProtocol.reset([.json(JiraFixtures.assignable)])
        let users = try await JiraTestSupport.adapter().assignableUsers(projectKey: "QA", query: "бо")
        XCTAssertEqual(users.map(\.displayName), ["Боб", "Я"])
        let url = try XCTUnwrap(JiraStubProtocol.recorded.first?.url)
        XCTAssertEqual(url.path, "/rest/api/3/user/assignable/search")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "project" }?.value, "QA")
        XCTAssertEqual(items.first { $0.name == "query" }?.value, "бо")
    }
}

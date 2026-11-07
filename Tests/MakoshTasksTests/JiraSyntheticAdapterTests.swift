import Foundation
import MakoshJira
import XCTest
@testable import MakoshTasks

final class JiraSyntheticAdapterTests: XCTestCase {
    func testSyntheticTransitionRequiresResolution() async throws {
        let jira = JiraSyntheticAdapter()
        let page = try await jira.searchIssues(jql: "assignee = currentUser()", nextToken: nil, limit: 50)
        XCTAssertEqual(page.items.count, 6)
        XCTAssertEqual(Set(page.items.map(\.projectKey)), ["QA", "OPS"])
        let first = try XCTUnwrap(page.items.first { $0.key == "QA-1" })
        let transitions = try await jira.transitions(issueID: first.id)
        let done = try XCTUnwrap(transitions.first { $0.to.category == .done })
        XCTAssertTrue(done.fields.contains { $0.key == "resolution" && $0.required })
        XCTAssertThrowsError(try JiraFieldSupport.validate(done, fields: [:]))
        try await jira.transition(issueID: first.id, transitionID: done.id, fields: ["resolution": .resolution(id: "10000")])
        let after = try await jira.issue(id: first.id)
        XCTAssertEqual(after.status.category, .done)
        let rich = try XCTUnwrap(page.items.first { $0.descriptionADF.map { !JiraADF.isSimple($0) } ?? false }, "one issue has a table")
        XCTAssertTrue(rich.descriptionText.contains("|"))
        let mentioned = page.items.filter { $0.assignee?.accountID != "me-1" }
        XCTAssertEqual(mentioned.count, 1, "one issue reaches the user by mention only")
    }

    func testSyntheticWorklogAppearsInIssueWorklogs() async throws {
        let jira = JiraSyntheticAdapter()
        let id = try await jira.addWorklog(issueID: "1001", started: Date(), seconds: 900, comment: "созвон")
        let worklogs = try await jira.worklogs(issueID: "1001")
        XCTAssertEqual(worklogs.map(\.id), [id])
        XCTAssertEqual(worklogs.first?.commentText, "созвон")
        let comment = try await jira.addComment(issueID: "1001", body: JiraADF.document(fromText: "Готово"))
        let comments = try await jira.comments(issueID: "1001", nextToken: nil)
        XCTAssertTrue(comments.items.contains { $0.id == comment && $0.bodyText == "Готово" })
        try await jira.assign(issueID: "1001", accountID: "bob-1")
        let reassigned = try await jira.issue(id: "1001")
        XCTAssertEqual(reassigned.assignee?.accountID, "bob-1")
        let users = try await jira.assignableUsers(projectKey: "QA", query: "бо")
        XCTAssertEqual(users.map(\.accountID), ["bob-1"])
    }

    func testFailNextProducesTheErrorOnce() async throws {
        let jira = JiraSyntheticAdapter()
        await jira.failNext(.transport(code: "timedOut"))
        do {
            _ = try await jira.addComment(issueID: "1001", body: JiraADF.document(fromText: "x"))
            XCTFail("the scripted failure must throw")
        } catch let error as JiraAdapterError { XCTAssertEqual(error, .transport(code: "timedOut")) }
        _ = try await jira.addComment(issueID: "1001", body: JiraADF.document(fromText: "y"))
        let comments = try await jira.comments(issueID: "1001", nextToken: nil)
        XCTAssertEqual(
            comments.items.filter { $0.bodyText == "x" || $0.bodyText == "y" }.count, 2, "the failed write still landed, as a timeout would"
        )
    }
}

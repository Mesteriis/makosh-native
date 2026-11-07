import Foundation
import XCTest
@testable import MakoshJira

final class JiraCloudAdapterWriteTests: XCTestCase {
    override func setUp() {
        super.setUp()
        JiraStubProtocol.reset([])
    }
    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }

    func testAddWorklogSendsStartedInJiraFormat() async throws {
        JiraStubProtocol.reset([.json(#"{"id":"w9","self":"https://jira.test/x"}"#, status: 201)])
        let id = try await JiraTestSupport.adapter().addWorklog(
            issueID: "10001", started: utc("2026-11-07T06:00:00.000Z"), seconds: 1800, comment: "созвон")
        XCTAssertEqual(id, "w9")
        let request = try XCTUnwrap(JiraStubProtocol.recorded.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/rest/api/3/issue/10001/worklog")
        let body = try XCTUnwrap(JiraStubProtocol.body(at: 0))
        XCTAssertEqual(body["started"] as? String, "2026-11-07T06:00:00.000+0000")
        XCTAssertEqual(body["timeSpentSeconds"] as? Int, 1800)
        let comment = try XCTUnwrap(body["comment"] as? [String: Any])
        XCTAssertEqual(comment["type"] as? String, "doc")
    }

    func testAddWorklogUnderSixtySecondsIsRefusedLocally() async throws {
        do {
            _ = try await JiraTestSupport.adapter().addWorklog(issueID: "10001", started: Date(), seconds: 59, comment: nil)
            XCTFail("59 seconds must be refused")
        } catch let error as JiraAdapterError {
            XCTAssertEqual(error, .invalidRequest)
        }
        XCTAssertTrue(JiraStubProtocol.recorded.isEmpty)
    }

    func testAddCommentSendsADF() async throws {
        JiraStubProtocol.reset([.json(#"{"id":"c9"}"#, status: 201)])
        let body = JiraADF.document(fromText: "Готово")
        let id = try await JiraTestSupport.adapter().addComment(issueID: "10001", body: body)
        XCTAssertEqual(id, "c9")
        XCTAssertEqual(JiraStubProtocol.recorded.first?.url?.path, "/rest/api/3/issue/10001/comment")
        let sent = try XCTUnwrap(JiraStubProtocol.body(at: 0))
        let adf = try XCTUnwrap(sent["body"] as? [String: Any])
        XCTAssertEqual(adf["type"] as? String, "doc")
    }

    func testTransitionSendsFields() async throws {
        JiraStubProtocol.reset([.noContent()])
        try await JiraTestSupport.adapter().transition(
            issueID: "10001", transitionID: "31", fields: ["resolution": .resolution(id: "10000"), "customfield_1": .text("ok")])
        let request = try XCTUnwrap(JiraStubProtocol.recorded.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/rest/api/3/issue/10001/transitions")
        let body = try XCTUnwrap(JiraStubProtocol.body(at: 0))
        XCTAssertEqual((body["transition"] as? [String: Any])?["id"] as? String, "31")
        let fields = try XCTUnwrap(body["fields"] as? [String: Any])
        XCTAssertEqual((fields["resolution"] as? [String: Any])?["id"] as? String, "10000")
        XCTAssertEqual(fields["customfield_1"] as? String, "ok")
    }

    func testTransitionWithUnsupportedRequiredFieldIsBlockedBeforeSend() throws {
        let cascade = JiraField(key: "customfield_7", name: "Area", required: true, schemaType: "option-with-child")
        let text = JiraField(key: "customfield_1", name: "Note", required: true, schemaType: "string")
        let optional = JiraField(key: "customfield_9", name: "Sprint", required: false, schemaType: "array")
        let transition = JiraTransition(
            id: "31", name: "Done", to: JiraStatus(id: "3", name: "Done", category: .done), fields: [cascade, text, optional])
        XCTAssertEqual(JiraFieldSupport.unsupportedRequired(transition).map(\.key), ["customfield_7"])
        XCTAssertTrue(JiraFieldSupport.isSupported(text))
        XCTAssertFalse(JiraFieldSupport.isSupported(cascade))
        XCTAssertThrowsError(try JiraFieldSupport.validate(transition, fields: ["customfield_1": .text("x")])) { error in
            XCTAssertEqual(error as? JiraAdapterError, .unsupportedFields(["customfield_7"]))
        }
        XCTAssertTrue(JiraStubProtocol.recorded.isEmpty)
    }

    func testRichDescriptionIsReadOnly() throws {
        let table = Data(
            #"{"type":"doc","version":1,"content":[{"type":"table","content":[{"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]}]}]}]}]}"#
                .utf8)
        let rich = JiraIssue(
            id: "1", key: "QA-1", projectKey: "QA", summary: "x", descriptionADF: table, descriptionText: "a",
            status: JiraStatus(id: "1", name: "To Do", category: .new), updated: Date(),
            browseURL: URL(string: "https://jira.test/browse/QA-1")!)
        let patch = JiraIssuePatch(descriptionADF: JiraADF.document(fromText: "plain"))
        XCTAssertThrowsError(try patch.validate(against: rich)) { error in
            XCTAssertEqual(error as? JiraAdapterError, .descriptionNotEditable)
        }
        XCTAssertNoThrow(try JiraIssuePatch(summary: "y").validate(against: rich), "other fields stay editable")
        var simple = rich
        simple.descriptionADF = JiraADF.document(fromText: "old")
        XCTAssertNoThrow(try patch.validate(against: simple))
        var empty = rich
        empty.descriptionADF = nil
        XCTAssertNoThrow(try patch.validate(against: empty), "an empty description can be written")
    }

    func testUpdateFieldsSendsOnlyThePatch() async throws {
        JiraStubProtocol.reset([.noContent()])
        let due = utc("2026-11-20T00:00:00.000Z")
        try await JiraTestSupport.adapter().updateFields(
            issueID: "10001", patch: JiraIssuePatch(summary: "Новое", priorityID: "2", due: .some(due), labels: ["a", "b"]))
        let request = try XCTUnwrap(JiraStubProtocol.recorded.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/rest/api/3/issue/10001")
        let fields = try XCTUnwrap(JiraStubProtocol.body(at: 0)?["fields"] as? [String: Any])
        XCTAssertEqual(fields["summary"] as? String, "Новое")
        XCTAssertEqual((fields["priority"] as? [String: Any])?["id"] as? String, "2")
        XCTAssertEqual(fields["duedate"] as? String, "2026-11-20")
        XCTAssertEqual(fields["labels"] as? [String], ["a", "b"])
        XCTAssertNil(fields["description"])
        JiraStubProtocol.reset([.noContent()])
        try await JiraTestSupport.adapter().updateFields(issueID: "10001", patch: JiraIssuePatch(due: .some(nil)))
        let cleared = try XCTUnwrap(JiraStubProtocol.body(at: 0)?["fields"] as? [String: Any])
        XCTAssertTrue(cleared["duedate"] is NSNull, "a double optional nil clears the due date")
    }

    func testAssignSendsAccountIDAndNullUnassigns() async throws {
        JiraStubProtocol.reset([.noContent(), .noContent()])
        try await JiraTestSupport.adapter().assign(issueID: "10001", accountID: "bob-1")
        try await JiraTestSupport.adapter().assign(issueID: "10001", accountID: nil)
        let requests = JiraStubProtocol.recorded
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "PUT"])
        XCTAssertEqual(requests.first?.url?.path, "/rest/api/3/issue/10001/assignee")
        XCTAssertEqual(JiraStubProtocol.body(at: 0)?["accountId"] as? String, "bob-1")
        XCTAssertTrue(JiraStubProtocol.body(at: 1)?["accountId"] is NSNull)
    }
}

import Foundation
import MakoshJira
import XCTest
@testable import MakoshTasks

/// The five actions as the card drives them, on the synthetic Jira.
@MainActor final class JiraActionsModelTests: XCTestCase {
    private struct Harness {
        let jira: JiraSyntheticAdapter
        let service: TasksService
        let model: TasksWorkspaceModel
        let connectionID: UUID
    }

    private func harness() async throws -> Harness {
        let db = try tasksDatabase()
        let store = TaskStore(connectionString: db.connectionString, schema: db.schema)
        let jira = JiraSyntheticAdapter()
        let service = TasksService(store: store, vault: JiraTokenVault(access: .memory()), adapterFactory: { _, _ in jira })
        try await service.open()
        try await TasksSyntheticSeed.seed(store: store)
        let connections = try await store.connections()
        let connection = try XCTUnwrap(connections.first)
        try await service.save(connection, token: "qa-token")
        let model = TasksWorkspaceModel(service: service)
        await model.refresh()
        await model.syncNow()
        return Harness(jira: jira, service: service, model: model, connectionID: connection.id)
    }
    private func task(_ h: Harness, key: String) throws -> Task {
        try XCTUnwrap(h.model.tasks.first { h.model.observation(id: $0.id)?.issue.key == key })
    }

    func testTransitionRequiringResolutionIsSentWithField() async throws {
        let h = try await harness()
        let task = try task(h, key: "QA-1")
        await h.model.refreshIssue(id: task.id)
        let done = try XCTUnwrap(h.model.observation(id: task.id)?.transitions.first { $0.to.category == .done })
        XCTAssertEqual(h.model.transitionRequirements(done).map(\.key), ["resolution"], "the card asks for the resolution")
        await h.model.jira(.transition(done, fields: ["resolution": .resolution(id: "10000")]), id: task.id)
        XCTAssertNil(h.model.error)
        XCTAssertEqual(h.model.attempts(id: task.id).last?.state, .confirmed)
        XCTAssertEqual(h.model.observation(id: task.id)?.issue.status.category, .done)
        XCTAssertEqual(h.model.task(id: task.id)?.status, .done, "a Done category completes the local task")
    }

    func testUnsupportedRequiredFieldBlocksSubmit() async throws {
        let h = try await harness()
        let task = try task(h, key: "QA-1")
        let cascade = JiraField(key: "customfield_7", name: "Area", required: true, schemaType: "option-with-child")
        let transition = JiraTransition(id: "99", name: "Odd", to: JiraSyntheticAdapter.done, fields: [cascade])
        XCTAssertEqual(h.model.blockedFields(transition).map(\.key), ["customfield_7"])
        await h.model.jira(.transition(transition, fields: [:]), id: task.id)
        XCTAssertEqual(h.model.error, TasksFailure.unsupportedFields(["customfield_7"]).errorDescription)
        XCTAssertTrue(h.model.attempts(id: task.id).isEmpty, "nothing was journaled or sent")
    }

    func testRichDescriptionIsNotEditable() async throws {
        let h = try await harness()
        let rich = try task(h, key: "QA-2")
        XCTAssertFalse(h.model.canEditDescription(id: rich.id))
        await h.model.jira(.fields(JiraIssuePatch(descriptionADF: JiraADF.document(fromText: "plain"))), id: rich.id)
        XCTAssertEqual(h.model.error, TasksFailure.descriptionNotEditable.errorDescription)
        XCTAssertTrue(h.model.attempts(id: rich.id).isEmpty)
        let simple = try task(h, key: "QA-1")
        XCTAssertTrue(h.model.canEditDescription(id: simple.id))
        await h.model.jira(
            .fields(JiraIssuePatch(summary: "Переименовано", descriptionADF: JiraADF.document(fromText: "Новый текст"))), id: simple.id)
        XCTAssertNil(h.model.error)
        XCTAssertEqual(h.model.observation(id: simple.id)?.issue.summary, "Переименовано")
        XCTAssertEqual(h.model.observation(id: simple.id)?.issue.descriptionText, "Новый текст")
    }

    func testAssignUnassignSendsNil() async throws {
        let h = try await harness()
        let task = try task(h, key: "QA-3")
        let users = await h.model.assignableUsers(id: task.id, query: "бо")
        XCTAssertEqual(users.map(\.accountID), ["bob-1"])
        await h.model.jira(.assign(accountID: "bob-1"), id: task.id)
        XCTAssertEqual(h.model.observation(id: task.id)?.issue.assignee?.accountID, "bob-1")
        XCTAssertEqual(
            h.model.task(id: task.id)?.source?.membership, .mentioned,
            "handed over, no mention, but still mirrored until the next full sync")
        await h.model.jira(.assign(accountID: nil), id: task.id)
        XCTAssertNil(h.model.observation(id: task.id)?.issue.assignee)
        await h.model.jira(.comment("Готово, смотри"), id: task.id)
        XCTAssertEqual(h.model.observation(id: task.id)?.comments.last?.bodyText, "Готово, смотри")
    }

    func testUnknownAttemptShowsResolveAndDismiss() async throws {
        let h = try await harness()
        let task = try task(h, key: "QA-1")
        await h.jira.failNext(.transport(code: "timedOut"))
        await h.model.jira(.comment("Потерянный ответ"), id: task.id)
        let unknown = try XCTUnwrap(h.model.attempts(id: task.id).last)
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertTrue(h.model.openAttempts(id: task.id).contains { $0.id == unknown.id })
        await h.model.resolveAttempt(id: unknown.id)
        XCTAssertEqual(h.model.attempts(id: task.id).last?.state, .confirmed, "the comment did land; the reread finds it")
        await h.jira.failNext(.transport(code: "networkFailure"))
        await h.model.jira(.assign(accountID: "ann-1"), id: task.id)
        let second = try XCTUnwrap(h.model.attempts(id: task.id).last)
        XCTAssertEqual(second.state, .unknown)
        await h.model.dismissAttempt(id: second.id)
        XCTAssertEqual(h.model.attempts(id: task.id).last?.state, .rejected)
        XCTAssertEqual(h.model.attempts(id: task.id).last?.reason, "отказ пользователя")
    }
}

import MakoshCore
import XCTest
@testable import MakoshAI

@MainActor
final class AIWorkspaceModelTests: XCTestCase {
    private var database: AITestDatabase!
    private var service: AIFakeService!
    private var worker: AIWorker!
    private let connection = AIConnection(name: "Synthetic", baseURL: URL(string: "http://127.0.0.1:9/v1")!)

    override func setUp() async throws {
        database = try AITestDatabase()
        service = AIFakeService()
        worker = AIWorker(
            repository: AIRepository(keyProvider: aiTestKey), client: service, vault: AIFakeVault(),
            images: AIImageStore(s3: nil, localDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    override func tearDown() async throws {
        await worker?.close()
        try database?.cleanup()
    }

    private func started() async throws -> AIWorkspaceModel {
        let model = AIWorkspaceModel(worker: worker)
        await model.start(configuration: database.configuration)
        let settings = AISettingsModel(worker: worker)
        await settings.save(connection, token: nil)
        await settings.assign(.chat, connectionID: connection.id, model: "m")
        await model.reload()
        return model
    }

    func testSendShowsStreamedAnswer() async throws {
        let model = try await started()
        await model.newConversation()
        await model.send("Привет")
        XCTAssertEqual(model.path.map { $0.current?.text }, ["Привет", "Hello"])
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.conversations.first?.title, "Привет")
    }

    func testSwitchConversationIgnoresStaleDeltas() async throws {
        service.hold = true
        let model = try await started()
        await model.newConversation()
        let first = try XCTUnwrap(model.selectedConversationID)
        let sending = Task { await model.send("q") }
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await worker.isStreaming(conversationID: first)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.newConversation()
        XCTAssertNotEqual(model.selectedConversationID, first)
        await worker.stop(conversationID: first)
        await sending.value
        XCTAssertTrue(model.path.isEmpty)
        XCTAssertFalse(model.isStreaming)
    }

    func testStopClearsStreaming() async throws {
        service.hold = true
        let model = try await started()
        await model.newConversation()
        let conversation = try XCTUnwrap(model.selectedConversationID)
        let sending = Task { await model.send("q") }
        let deadline = ContinuousClock.now + .seconds(10)
        while !model.isStreaming, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.isStreaming)
        model.stop()
        await sending.value
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.path.last?.current?.state, .interrupted)
        let streaming = await worker.isStreaming(conversationID: conversation)
        XCTAssertFalse(streaming)
    }

    func testReturningToStreamingConversationFollowsIt() async throws {
        service.hold = true
        let model = try await started()
        await model.newConversation()
        let first = try XCTUnwrap(model.selectedConversationID)
        let sending = Task { await model.send("q") }
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await worker.isStreaming(conversationID: first)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.newConversation()
        await model.select(first)
        XCTAssertTrue(model.isStreaming)
        model.stop()
        await sending.value
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.path.last?.current?.state, .interrupted)
    }

    func testWorkspaceFollowsSettingsRoles() async throws {
        let model = try await started()
        let settings = AISettingsModel(worker: worker)
        model.follow(settings)
        await settings.assign(.images, connectionID: connection.id, model: "img")
        let deadline = ContinuousClock.now + .seconds(10)
        while model.roles[.images] == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.roles[.images]?.model, "img")
    }

    func testUnassignedChatRoleShowsFailure() async throws {
        let model = AIWorkspaceModel(worker: worker)
        await model.start(configuration: database.configuration)
        await model.newConversation()
        await model.send("q")
        XCTAssertEqual(model.failure, .roleUnassigned(.chat))
        XCTAssertNil(model.roles[.chat])
    }

    func testSelectVersionSwitchesBranch() async throws {
        let model = try await started()
        await model.newConversation()
        await model.send("first")
        let question = try XCTUnwrap(model.path.first)
        service.deltas = ["Edited answer"]
        await model.edit(question.id, text: "second")
        XCTAssertEqual(model.path.map { $0.current?.text }, ["second", "Edited answer"])
        await model.selectVersion(0, of: question.id)
        XCTAssertEqual(model.path.map { $0.current?.text }, ["first", "Hello"])
    }

    func testDeleteSelectedConversationClearsPath() async throws {
        let model = try await started()
        await model.newConversation()
        await model.send("q")
        let id = try XCTUnwrap(model.selectedConversationID)
        await model.delete(id)
        XCTAssertNil(model.selectedConversationID)
        XCTAssertTrue(model.path.isEmpty)
        XCTAssertTrue(model.conversations.isEmpty)
    }

    func testSettingsTestStoresModelCount() async throws {
        let model = AIWorkspaceModel(worker: worker)
        await model.start(configuration: database.configuration)
        let settings = AISettingsModel(worker: worker)
        await settings.save(connection, token: "sk")
        await settings.test(connection.id)
        XCTAssertEqual(settings.availableModels[connection.id], ["m"])
        XCTAssertEqual(try settings.testResult[connection.id]?.get(), 1)
        XCTAssertEqual(settings.connections, [connection])
    }

    func testAssignNilClearsRole() async throws {
        let model = AIWorkspaceModel(worker: worker)
        await model.start(configuration: database.configuration)
        let settings = AISettingsModel(worker: worker)
        await settings.save(connection, token: nil)
        await settings.assign(.speech, connectionID: connection.id, model: "tts")
        XCTAssertEqual(settings.roles[.speech]?.model, "tts")
        await settings.assign(.speech, connectionID: nil, model: "")
        XCTAssertNil(settings.roles[.speech])
    }
}

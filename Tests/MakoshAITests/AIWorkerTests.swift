import MakoshCore
import XCTest
@testable import MakoshAI

actor AIFakeVault: AITokenStoring {
    private(set) var tokens: [UUID: String] = [:]
    func load(connectionID: UUID) -> String? { tokens[connectionID] }
    func save(_ token: String, connectionID: UUID) { tokens[connectionID] = token }
    func remove(connectionID: UUID) { tokens[connectionID] = nil }
}

/// Scripted provider. `hold` keeps a chat stream open after its deltas until
/// the consumer cancels it; `failAfter` ends it with an error instead of `[DONE]`.
final class AIFakeService: AIServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _deltas = ["Hel", "lo"]
    private var _hold = false
    private var _failure: AIFailure?
    private var _turns: [[AIChatTurn]] = []
    private var _calls = 0
    private var _imageHold = false
    private var _imageStarted = false
    var deltas: [String] {
        get { locked { _deltas } }
        set { locked { _deltas = newValue } }
    }
    var hold: Bool {
        get { locked { _hold } }
        set { locked { _hold = newValue } }
    }
    var failure: AIFailure? {
        get { locked { _failure } }
        set { locked { _failure = newValue } }
    }
    var imageHold: Bool {
        get { locked { _imageHold } }
        set { locked { _imageHold = newValue } }
    }
    var imageStarted: Bool { locked { _imageStarted } }
    var turns: [[AIChatTurn]] { locked { _turns } }
    var calls: Int { locked { _calls } }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func models(connection: AIConnection, token: String?) async throws -> [String] {
        locked { _calls += 1 }
        return ["m"]
    }
    func chat(connection: AIConnection, token: String?, model: String, turns: [AIChatTurn]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let (deltas, hold, failure) = locked {
            _calls += 1
            _turns.append(turns)
            return (_deltas, _hold, _failure)
        }
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(.delta(delta)) }
            if hold { return }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }
    func image(connection: AIConnection, token: String?, model: String, prompt: String) async throws -> Data {
        locked {
            _calls += 1
            _imageStarted = true
        }
        while imageHold {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        return Data("PNG-\(prompt)".utf8)
    }
    func transcribe(connection: AIConnection, token: String?, model: String, audio: URL) async throws -> String {
        locked { _calls += 1 }
        return "текст"
    }
    private var _embedded: [[String]] = []
    private var _embedFailure: AIFailure?
    private var _embedHold = false
    private var _embedStarted = 0
    private var _holdAtCall: Int?
    var holdAtCall: Int? {
        get { locked { _holdAtCall } }
        set { locked { _holdAtCall = newValue } }
    }
    var dimensions = 3
    var embedded: [[String]] { locked { _embedded } }
    var embedFailure: AIFailure? {
        get { locked { _embedFailure } }
        set { locked { _embedFailure = newValue } }
    }
    var embedHold: Bool {
        get { locked { _embedHold } }
        set { locked { _embedHold = newValue } }
    }
    var embedStarted: Int { locked { _embedStarted } }
    /// Deterministic vectors: one-hot by the first character, so a query finds text starting the same way.
    func embeddings(connection: AIConnection, token: String?, model: String, inputs: [String]) async throws -> [[Float]] {
        let failure = locked {
            _calls += 1
            _embedded.append(inputs)
            _embedStarted += 1
            return _embedFailure
        }
        let call = embedStarted
        while embedHold || holdAtCall == call {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        if let failure { throw failure }
        let dimensions = self.dimensions
        return inputs.map { input in
            var vector = [Float](repeating: 0.01, count: dimensions)
            vector[Int(input.unicodeScalars.first?.value ?? 0) % dimensions] = 1
            return vector
        }
    }
    func speech(connection: AIConnection, token: String?, model: String, text: String) async throws -> Data {
        locked { _calls += 1 }
        return Data("MP3".utf8)
    }
}

@discardableResult
func aiDrain(_ stream: AsyncThrowingStream<AIConversationEvent, Error>) async -> ([AIConversationEvent], Error?) {
    var events: [AIConversationEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch { return (events, error) }
}

final class AIWorkerTests: XCTestCase {
    private var database: AITestDatabase!
    private var service: AIFakeService!
    private var vault: AIFakeVault!
    private var worker: AIWorker!
    private var imageDirectory: URL!
    private let connection = AIConnection(name: "Synthetic", baseURL: URL(string: "http://127.0.0.1:9/v1")!)

    override func setUp() async throws {
        database = try AITestDatabase()
        service = AIFakeService()
        vault = AIFakeVault()
        imageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        worker = AIWorker(
            repository: AIRepository(keyProvider: aiTestKey), client: service, vault: vault,
            images: AIImageStore(s3: nil, localDirectory: imageDirectory))
        try await worker.open(configuration: database.configuration)
        try await worker.save(connection, token: "sk-synthetic")
        try await worker.assign(.init(role: .chat, connectionID: connection.id, model: "m"), role: .chat)
    }
    override func tearDown() async throws {
        await worker?.close()
        try database?.cleanup()
        if let imageDirectory { try? FileManager.default.removeItem(at: imageDirectory) }
    }

    private func path(_ conversation: UUID) async throws -> [AIMessage] {
        AIMessage.path(try await worker.messages(conversation))
    }
    private func waitForText(_ conversation: UUID, _ text: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if try await path(conversation).last?.current?.text == text { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("text \(text) never persisted")
    }

    func testSendStreamsAndPersistsComplete() async throws {
        let conversation = try await worker.createConversation()
        let (events, error) = await aiDrain(await worker.send("Привет", conversationID: conversation.id, editing: nil))
        XCTAssertNil(error)
        XCTAssertEqual(events.last, .finished(conversation.id))
        let messages = try await path(conversation.id)
        XCTAssertEqual(messages.map(\.author), [.user, .assistant])
        XCTAssertEqual(messages.map { $0.current?.text }, ["Привет", "Hello"])
        XCTAssertEqual(messages.last?.current?.state, .complete)
        XCTAssertEqual(service.turns.last, [.init(author: .user, text: "Привет")])
        let conversations = try await worker.snapshot().conversations
        XCTAssertEqual(conversations.first?.title, "Привет")
    }

    func testStopKeepsPartialAsInterrupted() async throws {
        service.hold = true
        service.deltas = ["part"]
        let conversation = try await worker.createConversation()
        let stream = await worker.send("q", conversationID: conversation.id, editing: nil)
        let consumer = Task { await aiDrain(stream) }
        try await waitForStreaming(conversation.id)
        await worker.stop(conversationID: conversation.id)
        let (_, error) = await consumer.value
        XCTAssertNil(error)
        let last = try await path(conversation.id).last
        XCTAssertEqual(last?.current?.text, "part")
        XCTAssertEqual(last?.current?.state, .interrupted)
    }

    private func waitForStreaming(_ conversation: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await worker.isStreaming(conversationID: conversation) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("stream never started")
    }

    func testStreamWithoutDoneIsInterrupted() async throws {
        service.failure = .network
        let conversation = try await worker.createConversation()
        let (_, error) = await aiDrain(await worker.send("q", conversationID: conversation.id, editing: nil))
        XCTAssertEqual(error as? AIFailure, .network)
        let last = try await path(conversation.id).last
        XCTAssertEqual(last?.current?.text, "Hello")
        XCTAssertEqual(last?.current?.state, .interrupted)
    }

    func testUnauthorizedMarksFailed() async throws {
        service.deltas = []
        service.failure = .unauthorized
        let conversation = try await worker.createConversation()
        let (_, error) = await aiDrain(await worker.send("q", conversationID: conversation.id, editing: nil))
        XCTAssertEqual(error as? AIFailure, .unauthorized)
        let last = try await path(conversation.id).last
        XCTAssertEqual(last?.current?.state, .failed)
    }

    func testRegenerateAddsVersionAndKeepsOld() async throws {
        let conversation = try await worker.createConversation()
        await aiDrain(await worker.send("q", conversationID: conversation.id, editing: nil))
        let answerPath = try await path(conversation.id)
        let answer = try XCTUnwrap(answerPath.last)
        service.deltas = ["Other"]
        await aiDrain(await worker.regenerate(answer.id, conversationID: conversation.id))
        let regeneratedPath = try await path(conversation.id)
        let regenerated = try XCTUnwrap(regeneratedPath.last)
        XCTAssertEqual(regenerated.id, answer.id)
        XCTAssertEqual(regenerated.versions.map(\.text), ["Hello", "Other"])
        XCTAssertEqual(regenerated.selectedVersion, 1)
        XCTAssertEqual(service.turns.last, [.init(author: .user, text: "q")])
    }

    func testEditCreatesBranch() async throws {
        let conversation = try await worker.createConversation()
        await aiDrain(await worker.send("first", conversationID: conversation.id, editing: nil))
        let questionPath = try await path(conversation.id)
        let question = try XCTUnwrap(questionPath.first)
        service.deltas = ["Second answer"]
        await aiDrain(await worker.send("edited", conversationID: conversation.id, editing: question.id))
        let edited = try await path(conversation.id)
        XCTAssertEqual(edited.map { $0.current?.text }, ["edited", "Second answer"])
        XCTAssertEqual(edited.first?.versions.map(\.text), ["first", "edited"])
        try await worker.selectVersion(0, messageID: question.id, conversationID: conversation.id)
        let original = try await path(conversation.id)
        XCTAssertEqual(original.map { $0.current?.text }, ["first", "Hello"])
    }

    func testFollowUpIncludesHistory() async throws {
        let conversation = try await worker.createConversation()
        await aiDrain(await worker.send("one", conversationID: conversation.id, editing: nil))
        await aiDrain(await worker.send("two", conversationID: conversation.id, editing: nil))
        XCTAssertEqual(
            service.turns.last,
            [.init(author: .user, text: "one"), .init(author: .assistant, text: "Hello"), .init(author: .user, text: "two")])
    }

    func testDeleteDuringStreamDiscardsDeltas() async throws {
        service.hold = true
        let conversation = try await worker.createConversation()
        let stream = await worker.send("q", conversationID: conversation.id, editing: nil)
        let consumer = Task { await aiDrain(stream) }
        try await waitForStreaming(conversation.id)
        try await worker.deleteConversation(conversation.id)
        _ = await consumer.value
        let messages = try await worker.messages(conversation.id)
        let conversations = try await worker.snapshot().conversations
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(conversations.isEmpty)
    }

    func testRoleUnassignedFailsWithoutNetwork() async throws {
        try await worker.assign(nil, role: .chat)
        let conversation = try await worker.createConversation()
        let calls = service.calls
        let (_, error) = await aiDrain(await worker.send("q", conversationID: conversation.id, editing: nil))
        XCTAssertEqual(error as? AIFailure, .roleUnassigned(.chat))
        XCTAssertEqual(service.calls, calls)
        let messages = try await worker.messages(conversation.id)
        XCTAssertTrue(messages.isEmpty)
    }

    func testSecondSendWhileStreamingRejected() async throws {
        service.hold = true
        let conversation = try await worker.createConversation()
        let stream = await worker.send("q", conversationID: conversation.id, editing: nil)
        let consumer = Task { await aiDrain(stream) }
        try await waitForStreaming(conversation.id)
        let (_, error) = await aiDrain(await worker.send("again", conversationID: conversation.id, editing: nil))
        XCTAssertEqual(error as? AIFailure, .busy)
        await worker.stop(conversationID: conversation.id)
        _ = await consumer.value
    }

    func testImageStoredLocallyWithoutS3AndDeletedWithConversation() async throws {
        try await worker.assign(.init(role: .images, connectionID: connection.id, model: "img"), role: .images)
        let conversation = try await worker.createConversation()
        let message = try await worker.generateImage(prompt: "cat", conversationID: conversation.id)
        let reference = try XCTUnwrap(message.current?.image)
        XCTAssertFalse(reference.inS3)
        let loaded = try await worker.image(reference, conversationID: conversation.id)
        XCTAssertEqual(loaded, Data("PNG-cat".utf8))
        let stored = try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)
        XCTAssertEqual(stored.count, 1)
        XCTAssertFalse(try Data(contentsOf: imageDirectory.appendingPathComponent(stored[0])).contains(Data("PNG-cat".utf8)))
        try await worker.deleteConversation(conversation.id)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path).isEmpty)
    }

    func testDeleteDuringImageGenerationLeavesNothing() async throws {
        try await worker.assign(.init(role: .images, connectionID: connection.id, model: "img"), role: .images)
        service.imageHold = true
        let conversation = try await worker.createConversation()
        let worker = self.worker!
        let generating = Task { try await worker.generateImage(prompt: "cat", conversationID: conversation.id) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !service.imageStarted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await worker.deleteConversation(conversation.id)
        service.imageHold = false
        _ = try? await generating.value
        let messages = try await worker.messages(conversation.id)
        XCTAssertTrue(messages.isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testImageWhileStreamingRejected() async throws {
        try await worker.assign(.init(role: .images, connectionID: connection.id, model: "img"), role: .images)
        service.hold = true
        let conversation = try await worker.createConversation()
        let stream = await worker.send("q", conversationID: conversation.id, editing: nil)
        let consumer = Task { await aiDrain(stream) }
        try await waitForStreaming(conversation.id)
        do {
            _ = try await worker.generateImage(prompt: "cat", conversationID: conversation.id)
            XCTFail("image generated during a stream")
        } catch { XCTAssertEqual(error as? AIFailure, .busy) }
        await worker.stop(conversationID: conversation.id)
        _ = await consumer.value
    }

    func testChangingOriginDropsStoredToken() async throws {
        var moved = connection
        moved.baseURL = URL(string: "http://127.0.0.1:9/other")!
        try await worker.save(moved, token: nil)
        let samePath = await vault.load(connectionID: connection.id)
        XCTAssertEqual(samePath, "sk-synthetic")
        moved.baseURL = URL(string: "https://proxy.example/v1")!
        try await worker.save(moved, token: nil)
        let otherOrigin = await vault.load(connectionID: connection.id)
        XCTAssertNil(otherOrigin)
    }

    func testRemoveConnectionRemovesToken() async throws {
        try await worker.removeConnection(connection.id)
        let token = await vault.load(connectionID: connection.id)
        XCTAssertNil(token)
        let snapshot = try await worker.snapshot()
        XCTAssertTrue(snapshot.connections.isEmpty)
        XCTAssertTrue(snapshot.roles.isEmpty)
    }

    func testTranscribeAndSpeechUseTheirRoles() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            _ = try await worker.transcribe(audio)
            XCTFail("unassigned role used")
        } catch { XCTAssertEqual(error as? AIFailure, .roleUnassigned(.transcription)) }
        try await worker.assign(.init(role: .transcription, connectionID: connection.id, model: "w"), role: .transcription)
        try await worker.assign(.init(role: .speech, connectionID: connection.id, model: "t"), role: .speech)
        let text = try await worker.transcribe(audio)
        let speech = try await worker.speech("hi")
        XCTAssertEqual(text, "текст")
        XCTAssertEqual(speech, Data("MP3".utf8))
    }
}

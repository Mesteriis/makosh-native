import XCTest
@testable import MakoshAI

/// Replies from a per-test table; each response body is delivered in the given chunks.
final class AIStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let chunks: [Data]
        let fail: Bool
        var redirect: URL? = nil
    }
    nonisolated(unsafe) static var reply = Reply(status: 200, chunks: [], fail: false)
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.bodies.append(data)
        } else {
            Self.bodies.append(request.httpBody ?? Data())
        }
        let reply = Self.reply
        if let target = reply.redirect, request.url?.host != target.host {
            var next = request
            next.url = target
            let redirect = HTTPURLResponse(
                url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            // A refused redirect completes with the redirect response itself.
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(
            self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if reply.fail {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class AIClientTests: XCTestCase {
    private let connection = AIConnection(name: "Cloud", baseURL: URL(string: "https://api.example.com/v1")!, organization: "org-1")
    private var client: AIClient!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStubProtocol.self]
        client = AIClient(session: URLSession(configuration: configuration))
        AIStubProtocol.requests = []
        AIStubProtocol.bodies = []
    }

    private func reply(_ chunks: [String], status: Int = 200, fail: Bool = false) {
        AIStubProtocol.reply = .init(status: status, chunks: chunks.map { Data($0.utf8) }, fail: fail)
    }
    private func collect(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async -> ([AIStreamEvent], Error?) {
        var events: [AIStreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch { return (events, error) }
    }
    private func chat() -> AsyncThrowingStream<AIStreamEvent, Error> {
        client.chat(connection: connection, token: "sk-1", model: "gpt", turns: [.init(author: .user, text: "Hi")])
    }

    func testSSEParsesDeltasAcrossChunks() async throws {
        reply([
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\ndata: {\"choices\":[{\"del",
            "ta\":{\"content\":\"lo\"}}]}\n\ndata: [DONE]\n\n",
        ])
        let (events, error) = await collect(chat())
        XCTAssertNil(error)
        XCTAssertEqual(events, [.delta("Hel"), .delta("lo"), .done])
        let request = try XCTUnwrap(AIStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Organization"), "org-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: AIStubProtocol.bodies[0]) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String, "gpt")
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first, ["role": "user", "content": "Hi"])
    }

    func testSSEIgnoresCommentsAndEmptyDelta() async {
        reply([
            ": keep-alive\n\ndata: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\ndata: [DONE]\n\n"
        ])
        let (events, error) = await collect(chat())
        XCTAssertNil(error)
        XCTAssertEqual(events, [.delta("x"), .done])
    }

    func testStreamWithoutDoneIsInterrupted() async {
        reply(["data: {\"choices\":[{\"delta\":{\"content\":\"part\"}}]}\n\n"])
        let (events, error) = await collect(chat())
        XCTAssertEqual(events, [.delta("part")])
        XCTAssertEqual(error as? AIFailure, .network)
    }

    func testTruncatedFinalEventIsInterrupted() async {
        reply(["data: {\"choices\":[{\"delta\":{\"content\":\"part\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"he"])
        let (events, error) = await collect(chat())
        XCTAssertEqual(events, [.delta("part")])
        XCTAssertEqual(error as? AIFailure, .network)
    }

    func testHTTPErrorsMapWithoutBody() async {
        for (status, expected) in [(401, AIFailure.unauthorized), (429, .rateLimited), (503, .server(status: 503))] {
            reply(["{\"error\":{\"message\":\"secret body sk-1\"}}"], status: status)
            let (events, error) = await collect(chat())
            XCTAssertTrue(events.isEmpty)
            XCTAssertEqual(error as? AIFailure, expected)
            XCTAssertFalse(String(describing: error as Any).contains("secret body"))
            XCTAssertFalse(String(describing: error as Any).contains("sk-1"))
        }
    }

    func testTokenTrimmedAndEmptyOmitsHeader() async throws {
        reply(["{\"data\":[]}"])
        _ = try await client.models(connection: connection, token: " sk-2\n")
        XCTAssertEqual(AIStubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-2")
        _ = try await client.models(connection: connection, token: "  ")
        XCTAssertNil(AIStubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"))
        _ = try await client.models(connection: connection, token: nil)
        XCTAssertNil(AIStubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"))
    }

    func testModelsSortedUnique() async throws {
        reply(["{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"},{\"id\":\"b\"}]}"])
        let models = try await client.models(connection: connection, token: nil)
        XCTAssertEqual(models, ["a", "b"])
        XCTAssertEqual(AIStubProtocol.requests.last?.url?.absoluteString, "https://api.example.com/v1/models")
    }

    func testImageDecodesB64() async throws {
        reply(["{\"data\":[{\"b64_json\":\"\(Data("PNG".utf8).base64EncodedString())\"}]}"])
        let image = try await client.image(connection: connection, token: nil, model: "img", prompt: "cat")
        XCTAssertEqual(image, Data("PNG".utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: AIStubProtocol.bodies[0]) as? [String: Any])
        XCTAssertEqual(body["response_format"] as? String, "b64_json")
        XCTAssertEqual(body["prompt"] as? String, "cat")
    }

    func testTranscriptionMultipart() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data("AUDIO".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        reply(["{\"text\":\"привет\"}"])
        let text = try await client.transcribe(connection: connection, token: nil, model: "whisper", audio: audio)
        XCTAssertEqual(text, "привет")
        let request = try XCTUnwrap(AIStubProtocol.requests.last)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: AIStubProtocol.bodies[0], as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"audio.m4a\""))
        XCTAssertTrue(body.contains("AUDIO"))
    }

    func testEmbeddingsOrderedByIndex() async throws {
        reply(["{\"data\":[{\"index\":1,\"embedding\":[0.5,0.5]},{\"index\":0,\"embedding\":[1,0]}]}"])
        let vectors = try await client.embeddings(connection: connection, token: nil, model: "emb", inputs: ["a", "b"])
        XCTAssertEqual(vectors, [[1, 0], [0.5, 0.5]])
        XCTAssertEqual(AIStubProtocol.requests.last?.url?.absoluteString, "https://api.example.com/v1/embeddings")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: AIStubProtocol.bodies[0]) as? [String: Any])
        XCTAssertEqual(body["input"] as? [String], ["a", "b"])
        reply(["{\"data\":[{\"index\":0,\"embedding\":[1,0]}]}"])
        do {
            _ = try await client.embeddings(connection: connection, token: nil, model: "emb", inputs: ["a", "b"])
            XCTFail("missing vector accepted")
        } catch { XCTAssertEqual(error as? AIFailure, .malformedResponse) }
    }

    func testSpeechReturnsAudio() async throws {
        reply(["MP3"])
        let audio = try await client.speech(connection: connection, token: nil, model: "tts", text: "hi")
        XCTAssertEqual(audio, Data("MP3".utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: AIStubProtocol.bodies[0]) as? [String: Any])
        XCTAssertEqual(body["voice"] as? String, "alloy")
        XCTAssertEqual(body["response_format"] as? String, "mp3")
    }

    func testRedirectToAnotherOriginIsRefused() async throws {
        AIStubProtocol.reply = .init(
            status: 200, chunks: [Data("data: [DONE]\n".utf8)], fail: false,
            redirect: URL(string: "http://evil.example/v1/chat/completions")!)
        let (_, error) = await collect(chat())
        XCTAssertNotNil(error)
        do {
            _ = try await client.models(connection: connection, token: "sk-1")
            XCTFail("redirected request accepted")
        } catch {}
        XCTAssertFalse(AIStubProtocol.requests.contains { $0.url?.host == "evil.example" })
    }
}

import Foundation

public struct AIChatTurn: Sendable, Equatable {
    public let author: AIMessageAuthor
    public let text: String
    public init(author: AIMessageAuthor, text: String) {
        self.author = author
        self.text = text
    }
}

public protocol AIServing: Sendable {
    func models(connection: AIConnection, token: String?) async throws -> [String]
    func chat(connection: AIConnection, token: String?, model: String, turns: [AIChatTurn]) -> AsyncThrowingStream<AIStreamEvent, Error>
    func image(connection: AIConnection, token: String?, model: String, prompt: String) async throws -> Data
    func transcribe(connection: AIConnection, token: String?, model: String, audio: URL) async throws -> String
    func speech(connection: AIConnection, token: String?, model: String, text: String) async throws -> Data
    func embeddings(connection: AIConnection, token: String?, model: String, inputs: [String]) async throws -> [[Float]]
}

/// OpenAI-compatible HTTP client. Request and response bodies are never
/// logged, and errors carry only the HTTP status class.
public struct AIClient: AIServing {
    private static let jsonLimit = 4 * 1024 * 1024
    private static let mediaLimit = 32 * 1024 * 1024
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public func models(connection: AIConnection, token: String?) async throws -> [String] {
        struct Response: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let request = try self.request(connection, token: token, path: "models", method: "GET")
        let response: Response = try decode(try await load(request, limit: Self.jsonLimit))
        return Array(Set(response.data.map(\.id))).sorted()
    }

    public func chat(
        connection: AIConnection, token: String?, model: String, turns: [AIChatTurn]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try self.request(connection, token: token, path: "chat/completions", method: "POST")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model, "stream": true,
                        "messages": turns.map { ["role": $0.author.rawValue, "content": $0.text] },
                    ])
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.check(response)
                    var parser = AIServerSentEvents()
                    // An unparsable line is only an error when more follows; as the
                    // last line it is an event cut off by a dropped connection.
                    var truncated = false
                    for try await line in bytes.lines {
                        if truncated { throw AIFailure.malformedResponse }
                        let parsed: AIStreamEvent?
                        do { parsed = try parser.feed(line) } catch {
                            truncated = true
                            continue
                        }
                        guard let event = parsed else { continue }
                        continuation.yield(event)
                        if event == .done {
                            continuation.finish()
                            return
                        }
                    }
                    throw AIFailure.network
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func image(connection: AIConnection, token: String?, model: String, prompt: String) async throws -> Data {
        struct Response: Decodable {
            struct Image: Decodable { let b64_json: String }
            let data: [Image]
        }
        var request = try self.request(connection, token: token, path: "images/generations", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "n": 1, "response_format": "b64_json",
        ])
        let response: Response = try decode(try await load(request, limit: Self.mediaLimit * 2))
        guard let encoded = response.data.first?.b64_json, let image = Data(base64Encoded: encoded), !image.isEmpty,
            image.count <= Self.mediaLimit
        else { throw AIFailure.malformedResponse }
        return image
    }

    public func transcribe(connection: AIConnection, token: String?, model: String, audio: URL) async throws -> String {
        struct Response: Decodable { let text: String }
        let file: Data
        do { file = try Data(contentsOf: audio) } catch { throw AIFailure.invalidConfiguration }
        guard !file.isEmpty, file.count <= Self.mediaLimit else { throw AIFailure.invalidConfiguration }
        let boundary = "makosh-" + UUID().uuidString
        var body = Data()
        func part(_ header: String, _ value: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; \(header)\r\n\r\n".utf8))
            body.append(value)
            body.append(Data("\r\n".utf8))
        }
        part("name=\"model\"", Data(model.utf8))
        part(
            "name=\"file\"; filename=\"audio.\(audio.pathExtension.isEmpty ? "m4a" : audio.pathExtension)\"\r\nContent-Type: application/octet-stream",
            file)
        body.append(Data("--\(boundary)--\r\n".utf8))
        var request = try self.request(connection, token: token, path: "audio/transcriptions", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let response: Response = try decode(try await load(request, limit: Self.jsonLimit))
        return response.text
    }

    public func speech(connection: AIConnection, token: String?, model: String, text: String) async throws -> Data {
        var request = try self.request(connection, token: token, path: "audio/speech", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": text, "voice": "alloy", "response_format": "mp3",
        ])
        let audio = try await load(request, limit: Self.mediaLimit)
        guard !audio.isEmpty else { throw AIFailure.malformedResponse }
        return audio
    }

    public func embeddings(connection: AIConnection, token: String?, model: String, inputs: [String]) async throws -> [[Float]] {
        struct Response: Decodable {
            struct Item: Decodable {
                let index: Int
                let embedding: [Float]
            }
            let data: [Item]
        }
        guard !inputs.isEmpty, inputs.count <= 256 else { throw AIFailure.invalidConfiguration }
        var request = try self.request(connection, token: token, path: "embeddings", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": inputs, "encoding_format": "float"])
        let response: Response = try decode(try await load(request, limit: Self.mediaLimit))
        let ordered = response.data.sorted { $0.index < $1.index }
        guard ordered.map(\.index) == Array(inputs.indices), let width = ordered.first?.embedding.count, width > 0,
            ordered.allSatisfy({ $0.embedding.count == width && $0.embedding.allSatisfy(\.isFinite) })
        else { throw AIFailure.malformedResponse }
        return ordered.map(\.embedding)
    }

    private func request(_ connection: AIConnection, token: String?, path: String, method: String) throws -> URLRequest {
        let connection = try connection.validated()
        var request = URLRequest(url: connection.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 120
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let organization = connection.organization { request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization") }
        if let project = connection.project { request.setValue(project, forHTTPHeaderField: "OpenAI-Project") }
        return request
    }

    private func load(_ request: URLRequest, limit: Int) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            try Self.check(response)
            guard data.count <= limit else { throw AIFailure.malformedResponse }
            return data
        } catch { throw Self.map(error) }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw AIFailure.malformedResponse }
    }

    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw AIFailure.malformedResponse }
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw AIFailure.unauthorized
        case 429: throw AIFailure.rateLimited
        default: throw AIFailure.server(status: response.statusCode)
        }
    }

    private static func map(_ error: Error) -> AIFailure {
        if let failure = error as? AIFailure { return failure }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        return .network
    }
}

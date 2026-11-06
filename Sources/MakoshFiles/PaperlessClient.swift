import Foundation

public struct PaperlessStatus: Equatable, Sendable {
    public let documentCount: Int
    public let version: String?
    public init(documentCount: Int, version: String?) {
        self.documentCount = documentCount
        self.version = version
    }
}

public struct PaperlessNamed: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct PaperlessDocument: Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let created: Date?
    public let documentType: Int?
    public let tags: [Int]
    public let originalFileName: String?
    public init(id: Int, title: String, created: Date?, documentType: Int?, tags: [Int], originalFileName: String?) {
        self.id = id
        self.title = title
        self.created = created
        self.documentType = documentType
        self.tags = tags
        self.originalFileName = originalFileName
    }
}

public struct PaperlessPage<T: Sendable>: Sendable {
    public let items: [T]
    public let hasMore: Bool
    public init(items: [T], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}

public enum PaperlessTaskState: Equatable, Sendable {
    case pending, started
    case success(documentID: Int?)
    case failure(message: String)
}

public struct PaperlessUpload: Equatable, Sendable {
    public var title: String
    public var created: Date?
    public var documentType: Int?
    public var tags: [Int]
    public init(title: String, created: Date? = nil, documentType: Int? = nil, tags: [Int] = []) {
        self.title = title
        self.created = created
        self.documentType = documentType
        self.tags = tags
    }
}

extension PaperlessUpload {
    public static let titleLimit = 128

    /// What the send sheet starts with: the file name without its extension,
    /// the message date, and the connection's default type and tags.
    public static func defaults(for handoff: FileHandoff, connection: PaperlessConnection) -> PaperlessUpload {
        var title = handoff.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (title as NSString).deletingPathExtension
        if !stem.isEmpty { title = stem }
        if title.isEmpty { title = "Документ" }
        return PaperlessUpload(
            title: String(title.prefix(titleLimit)), created: handoff.date, documentType: connection.defaultDocumentType,
            tags: connection.defaultTags)
    }
}

/// Paperless-ngx REST client: one token, one base URL, no redirects, bounded uploads.
public actor PaperlessClient {
    public static let apiVersion = 9
    public static let uploadLimit: Int64 = 512 * 1024 * 1024
    private static let bodyLimit = 32 * 1024 * 1024
    private static let listPages = 50
    private let connection: PaperlessConnection
    private let token: String
    private let session: URLSession
    private let redirects = RedirectRefuser()

    public init(connection: PaperlessConnection, token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.connection = connection
        self.token = token
        self.session = session
    }

    nonisolated public func documentURL(id: Int) -> URL {
        connection.baseURL.appendingPathComponent("documents/\(id)/details")
    }

    public func status() async throws -> PaperlessStatus {
        let (object, response) = try await json(request(path: "api/documents/", query: [("page_size", "1")]))
        guard let count = Self.int(object["count"]) else { throw FilesFailure.unexpectedResponse }
        return PaperlessStatus(documentCount: count, version: response.value(forHTTPHeaderField: "X-Version"))
    }

    public func tags() async throws -> [PaperlessNamed] { try await named("api/tags/") }
    public func documentTypes() async throws -> [PaperlessNamed] { try await named("api/document_types/") }

    public func documents(query: String, page: Int) async throws -> PaperlessPage<PaperlessDocument> {
        var items: [(String, String)] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(("query", trimmed)) }
        items += [("ordering", "-created"), ("page_size", "50"), ("page", String(max(page, 1)))]
        let (object, _) = try await json(request(path: "api/documents/", query: items))
        guard let results = object["results"] as? [[String: Any]] else { throw FilesFailure.unexpectedResponse }
        let documents = try results.map { entry -> PaperlessDocument in
            guard let id = Self.int(entry["id"]) else { throw FilesFailure.unexpectedResponse }
            return PaperlessDocument(
                id: id, title: entry["title"] as? String ?? "", created: Self.date(entry["created"]),
                documentType: Self.int(entry["document_type"]), tags: (entry["tags"] as? [Any])?.compactMap(Self.int) ?? [],
                originalFileName: entry["original_file_name"] as? String)
        }
        return PaperlessPage(items: documents, hasMore: object["next"] is String)
    }

    public func download(id: Int, original: Bool, to destination: URL) async throws {
        var request = request(path: "api/documents/\(id)/download/", query: original ? [("original", "true")] : [])
        request.setValue("application/json; version=\(Self.apiVersion)", forHTTPHeaderField: "Accept")
        let (file, response): (URL, URLResponse)
        do { (file, response) = try await session.download(for: request, delegate: redirects) } catch { throw Self.transport(error) }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw FilesFailure.unexpectedResponse }
        guard (200...299).contains(http.statusCode) else {
            throw Self.rejection(
                http, body: (try? Data(contentsOf: file, options: .mappedIfSafe)).map { $0.prefix(4096) } ?? Data(), token: token)
        }
        do { try FileManager.default.copyItem(at: file, to: destination) } catch { throw FilesFailure.unexpectedResponse }
    }

    /// Streams a multipart body from a private temporary file; returns the consumption task ID.
    public func upload(file: URL, name: String, options: PaperlessUpload) async throws -> String {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard let values, values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw FilesFailure.unexpectedResponse
        }
        guard Int64(size) <= Self.uploadLimit else { throw FilesFailure.tooLarge }
        let boundary = "makosh-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "makosh-paperless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = directory.appendingPathComponent("body")
        try Self.writeMultipart(to: body, boundary: boundary, file: file, name: name, options: options)
        var request = request(path: "api/documents/post_document/", query: [])
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (object, _) = try await perform(request, upload: body)
        guard let task = object as? String, !task.isEmpty else { throw FilesFailure.unexpectedResponse }
        return task
    }

    public func task(id: String) async throws -> PaperlessTaskState {
        let (object, _) = try await perform(request(path: "api/tasks/", query: [("task_id", id)]), upload: nil)
        guard let list = object as? [[String: Any]], let entry = list.first, let status = entry["status"] as? String else {
            throw FilesFailure.unexpectedResponse
        }
        switch status.uppercased() {
        case "PENDING": return .pending
        case "STARTED", "RETRY": return .started
        case "SUCCESS": return .success(documentID: Self.int(entry["related_document"]))
        default: return .failure(message: Self.clean(entry["result"] as? String ?? status, token: token))
        }
    }

    // MARK: - Requests

    private func named(_ path: String) async throws -> [PaperlessNamed] {
        var result: [PaperlessNamed] = []
        var next: URLRequest? = request(path: path, query: [("page_size", "100")])
        for _ in 0..<Self.listPages {
            guard let current = next else { break }
            let (object, _) = try await json(current)
            guard let results = object["results"] as? [[String: Any]] else { throw FilesFailure.unexpectedResponse }
            for entry in results {
                guard let id = Self.int(entry["id"]), let name = entry["name"] as? String else { throw FilesFailure.unexpectedResponse }
                result.append(PaperlessNamed(id: id, name: name))
            }
            next = nil
            if let link = object["next"] as? String, let url = URL(string: link), url.host == connection.baseURL.host,
                url.scheme == connection.baseURL.scheme
            {
                next = request(url: url)
            }
        }
        return result
    }

    private func request(path: String, query: [(String, String)]) -> URLRequest {
        var components = URLComponents(url: connection.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return request(url: components.url!)
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; version=\(Self.apiVersion)", forHTTPHeaderField: "Accept")
        return request
    }

    private func json(_ request: URLRequest) async throws -> ([String: Any], HTTPURLResponse) {
        let (object, response) = try await perform(request, upload: nil)
        guard let dictionary = object as? [String: Any] else { throw FilesFailure.unexpectedResponse }
        return (dictionary, response)
    }

    /// One request; a `406` is retried once without the version header.
    private func perform(_ request: URLRequest, upload: URL?) async throws -> (Any, HTTPURLResponse) {
        var (data, response) = try await exchange(request, upload: upload)
        if response.statusCode == 406 {
            var retry = request
            retry.setValue("application/json", forHTTPHeaderField: "Accept")
            (data, response) = try await exchange(retry, upload: upload)
        }
        guard (200...299).contains(response.statusCode) else { throw Self.rejection(response, body: data, token: token) }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard type.contains("application/json"), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            throw FilesFailure.unexpectedResponse
        }
        return (object, response)
    }

    private func exchange(_ request: URLRequest, upload: URL?) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            if let upload {
                (data, response) = try await session.upload(for: request, fromFile: upload, delegate: redirects)
            } else {
                (data, response) = try await session.data(for: request, delegate: redirects)
            }
        } catch { throw Self.transport(error) }
        guard let http = response as? HTTPURLResponse, data.count <= Self.bodyLimit else { throw FilesFailure.unexpectedResponse }
        return (data, http)
    }

    private static func rejection(_ response: HTTPURLResponse, body: Data, token: String) -> FilesFailure {
        switch response.statusCode {
        case 401, 403: return .unauthorized
        case 413: return .tooLarge
        default:
            var reason = ""
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                reason = (object["detail"] as? String) ?? (object["error"] as? String) ?? ""
            }
            return .rejected(status: response.statusCode, reason: String(clean(reason, token: token).prefix(160)))
        }
    }

    private static func transport(_ error: Error) -> FilesFailure {
        guard let error = error as? URLError else { return .unreachable(String(describing: type(of: error))) }
        let code: String
        switch error.code {
        case .cannotConnectToHost: code = "cannotConnectToHost"
        case .cannotFindHost: code = "cannotFindHost"
        case .timedOut: code = "timedOut"
        case .notConnectedToInternet: code = "notConnectedToInternet"
        case .networkConnectionLost: code = "networkConnectionLost"
        case .secureConnectionFailed: code = "secureConnectionFailed"
        case .serverCertificateUntrusted: code = "serverCertificateUntrusted"
        case .cancelled: code = "cancelled"
        default: code = "URLError \(error.code.rawValue)"
        }
        return .unreachable(code)
    }

    /// Texts shown to a person never carry the token, whatever the server echoed.
    private static func clean(_ text: String, token: String) -> String {
        token.isEmpty ? text : text.replacingOccurrences(of: token, with: "[скрыто]")
    }

    // MARK: - Parsing

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if text.count == 10 { return dayFormatter.date(from: text) }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    // MARK: - Multipart

    private static func writeMultipart(to destination: URL, boundary: String, file: URL, name: String, options: PaperlessUpload) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw FilesFailure.unexpectedResponse
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        func field(_ name: String, _ value: String) throws {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try field("title", options.title)
        if let created = options.created { try field("created", day(created)) }
        if let type = options.documentType { try field("document_type", String(type)) }
        for tag in options.tags { try field("tags", String(tag)) }
        let filename = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(
            of: "\n", with: " ")
        try output.write(
            contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"document\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                    .utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}

/// Every redirect is refused: the response itself is returned to the caller.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

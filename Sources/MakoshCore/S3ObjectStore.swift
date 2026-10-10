import Foundation
import CryptoKit
import Darwin

public enum S3ObjectStoreError: LocalizedError, Equatable {
    case configuration, invalid, unavailable, integrity, conflict, uncertain
    public var errorDescription: String? {
        switch self {
        case .configuration: "Некорректная конфигурация хранилища S3."
        case .invalid: "Некорректный объект или файл S3."
        case .unavailable: "Хранилище S3 недоступно."
        case .integrity: "Проверка целостности объекта S3 не пройдена."
        case .conflict: "Объект S3 уже существует с другим содержимым."
        case .uncertain: "Результат сохранения S3 не подтверждён. Проверьте состояние объекта."
        }
    }
}

public struct S3ObjectStoreConfiguration: Codable, Sendable {
    public let endpoint: String
    public let region: String
    public let bucket: String
    public let accessKeyID: String
    public let secretAccessKey: String
    public init(endpoint: String, region: String, bucket: String, accessKeyID: String, secretAccessKey: String) throws {
        self.endpoint = endpoint; self.region = region; self.bucket = bucket
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey
        try validate()
    }
    public init(from decoder: Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(endpoint: values.decode(String.self, forKey: .endpoint), region: values.decode(String.self, forKey: .region),
                bucket: values.decode(String.self, forKey: .bucket), accessKeyID: values.decode(String.self, forKey: .accessKeyID),
                secretAccessKey: values.decode(String.self, forKey: .secretAccessKey))
        } catch { throw S3ObjectStoreError.configuration }
    }
    func validate() throws {
        guard let c = URLComponents(string: endpoint), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.percentEncodedPath == "" || c.percentEncodedPath == "/",
              c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())),
              c.port == nil || (1...65535).contains(c.port!),
              !endpoint.utf8.contains(where: { $0 < 33 || $0 > 126 }),
              (1...64).contains(region.utf8.count), region.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              (3...63).contains(bucket.utf8.count), bucket.first != "-", bucket.last != "-",
              bucket.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              (1...128).contains(accessKeyID.utf8.count), accessKeyID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              (1...256).contains(secretAccessKey.utf8.count), secretAccessKey.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw S3ObjectStoreError.configuration
        }
    }
}

public struct S3ObjectReceipt: Equatable, Sendable {
    public let key: String
    public let byteCount: Int64
    public let sha256: String
}

// AWS S3 SigV4 single-chunk signed payload algorithm, including the empty GET/HEAD payload.
// https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
struct S3Signer {
    static let emptyHash = hex(SHA256.hash(data: Data()))
    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func authorization(method: String, path: String, headers: [String: String], payloadHash: String,
                              timestamp: String, region: String, accessKey: String, secret: String) -> String {
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { key in
            key + ":" + headers[key]!.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") + "\n"
        }.joined()
        let signed = names.joined(separator: ";")
        let canonical = method + "\n" + path + "\n\n" + canonicalHeaders + "\n" + signed + "\n" + payloadHash
        let day = String(timestamp.prefix(8))
        let scope = day + "/" + region + "/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n" + timestamp + "\n" + scope + "\n" + hex(SHA256.hash(data: Data(canonical.utf8)))
        func hmac(_ key: Data, _ value: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
        }
        let dateKey = hmac(Data(("AWS4" + secret).utf8), day)
        let regionKey = hmac(dateKey, region)
        let serviceKey = hmac(regionKey, "s3")
        let key = hmac(serviceKey, "aws4_request")
        return "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope),SignedHeaders=\(signed),Signature=\(hex(hmac(key, toSign)))"
    }
    static func validateKey(_ key: String) throws {
        guard (1...1024).contains(key.utf8.count), key.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [47,45,46,95].contains($0)
        }), key.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw S3ObjectStoreError.invalid
        }
    }
    static func validateHash(_ hash: String, count: Int64) throws {
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              count >= 0, count <= 4 * 1024 * 1024 * 1024 + 1024 * 1024 else { throw S3ObjectStoreError.invalid }
    }
}

public actor S3ObjectStore {
    private let configuration: S3ObjectStoreConfiguration
    public init(configuration: S3ObjectStoreConfiguration) throws {
        try configuration.validate(); self.configuration = configuration
    }
    private func request(_ method: String, key: String, payload: String = S3Signer.emptyHash,
                         extra: [String: String] = [:]) throws -> URLRequest {
        try S3Signer.validateKey(key)
        guard var components = URLComponents(string: configuration.endpoint) else { throw S3ObjectStoreError.configuration }
        components.percentEncodedPath = "/" + configuration.bucket + "/" + key
        guard let url = components.url, let host = components.host else { throw S3ObjectStoreError.configuration }
        let hostName = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        let hostHeader = hostName + (components.port.map { ":\($0)" } ?? "")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: Date())
        var headers = extra
        headers["host"] = hostHeader; headers["x-amz-date"] = timestamp; headers["x-amz-content-sha256"] = payload
        var result = URLRequest(url: url); result.httpMethod = method
        for (name, value) in headers { result.setValue(value, forHTTPHeaderField: name) }
        result.setValue(S3Signer.authorization(method: method, path: components.percentEncodedPath, headers: headers,
            payloadHash: payload, timestamp: timestamp, region: configuration.region,
            accessKey: configuration.accessKeyID, secret: configuration.secretAccessKey), forHTTPHeaderField: "Authorization")
        result.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return result
    }
    public func head(key: String) async throws -> S3ObjectReceipt? {
        let req = try request("HEAD", key: key)
        do {
            let response = try await S3Transfer.execute(req, upload: nil, download: false, byteLimit: 0).response
            if response.statusCode == 404 { return nil }
            guard response.statusCode == 200 else { throw S3ObjectStoreError.unavailable }
            return try Self.receipt(response, key: key)
        } catch is CancellationError { throw CancellationError() }
        catch let error as S3ObjectStoreError { throw error }
        catch { throw S3ObjectStoreError.unavailable }
    }
    public func put(file: URL, key: String, sha256: String, byteCount: Int64) async throws -> S3ObjectReceipt {
        try S3Signer.validateKey(key); try S3Signer.validateHash(sha256, count: byteCount)
        // Upload only a verified owned snapshot; URLSession cannot follow a later source-path replacement.
        let staged = try await S3LocalFile.stage(file, hash: sha256, count: byteCount)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        let req = try request("PUT", key: key, payload: sha256, extra: [
            "content-length": String(byteCount), "x-amz-meta-sha256": sha256, "if-none-match": "*"
        ])
        let response: HTTPURLResponse
        do { response = try await S3Transfer.execute(req, upload: staged, download: false, byteLimit: 0).response }
        catch is CancellationError { throw CancellationError() }
        catch {
            // No second PUT. A lost response can mean a committed object.
            return try await reconcile(key: key, hash: sha256, count: byteCount)
        }
        if (200...299).contains(response.statusCode) {
            return S3ObjectReceipt(key: key, byteCount: byteCount, sha256: sha256)
        }
        if response.statusCode == 412 || response.statusCode == 409 || response.statusCode >= 500 {
            return try await reconcile(key: key, hash: sha256, count: byteCount)
        }
        throw S3ObjectStoreError.unavailable
    }
    private func reconcile(key: String, hash: String, count: Int64) async throws -> S3ObjectReceipt {
        let receipt: S3ObjectReceipt?
        do { receipt = try await head(key: key) }
        catch is CancellationError { throw CancellationError() }
        catch { throw S3ObjectStoreError.uncertain }
        guard let receipt else { throw S3ObjectStoreError.uncertain }
        guard receipt.sha256 == hash, receipt.byteCount == count else { throw S3ObjectStoreError.conflict }
        return receipt
    }
    public func download(key: String, to destination: URL, sha256: String, byteCount: Int64) async throws {
        try S3Signer.validateKey(key); try S3Signer.validateHash(sha256, count: byteCount)
        let req = try request("GET", key: key)
        let result: S3Transfer.Result
        do { result = try await S3Transfer.execute(req, upload: nil, download: true, byteLimit: byteCount) }
        catch is CancellationError { throw CancellationError() }
        catch { throw S3ObjectStoreError.unavailable }
        guard let temporary = result.file else { throw S3ObjectStoreError.unavailable }
        defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
        guard result.response.statusCode == 200 else { throw S3ObjectStoreError.unavailable }
        let receipt = try Self.receipt(result.response, key: key)
        guard receipt.sha256 == sha256, receipt.byteCount == byteCount else { throw S3ObjectStoreError.integrity }
        try await S3LocalFile.export(temporary, destination: destination, hash: sha256, count: byteCount)
    }
    private static func receipt(_ response: HTTPURLResponse, key: String) throws -> S3ObjectReceipt {
        guard let length = response.value(forHTTPHeaderField: "Content-Length"),
              !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int64(length),
              let hash = response.value(forHTTPHeaderField: "x-amz-meta-sha256") else { throw S3ObjectStoreError.integrity }
        try S3Signer.validateHash(hash, count: count)
        return S3ObjectReceipt(key: key, byteCount: count, sha256: hash)
    }
}

final class S3Transfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Result: Sendable { let response: HTTPURLResponse; let file: URL? }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Error>?
    private var task: URLSessionTask?
    private var session: URLSession?
    private var cancelled = false
    private var failed = false
    private var responseBytes = 0
    private var temporary: URL?
    private let limit: Int64
    private let isDownload: Bool
    init(limit: Int64, download: Bool) { self.limit = limit; self.isDownload = download }
    static func execute(_ request: URLRequest, upload: URL?, download: Bool, byteLimit: Int64) async throws -> Result {
        let transfer = S3Transfer(limit: byteLimit, download: download)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                transfer.lock.lock()
                transfer.continuation = continuation
                if transfer.cancelled {
                    transfer.continuation = nil; transfer.lock.unlock()
                    continuation.resume(throwing: CancellationError()); return
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 300
                let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
                transfer.session = session
                let task: URLSessionTask
                if let upload { task = session.uploadTask(with: request, fromFile: upload) }
                else if download { task = session.downloadTask(with: request) }
                else { task = session.dataTask(with: request) }
                transfer.task = task; transfer.lock.unlock(); task.resume()
            }
        } onCancel: { transfer.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
    }
    // Never forward any signed header to another URL, even same-origin redirects.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBytes += data.count
        if responseBytes > 64 * 1024 { failed = true; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite != limit {
            failed = true; downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard !failed, let response = downloadTask.response as? HTTPURLResponse,
                  response.expectedContentLength == limit else { throw S3ObjectStoreError.integrity }
            let directory = try S3LocalFile.directory()
            let file = directory.appendingPathComponent("payload")
            do { try FileManager.default.moveItem(at: location, to: file) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
            guard chmod(file.path, 0o600) == 0 else {
                try? FileManager.default.removeItem(at: directory); throw S3ObjectStoreError.unavailable
            }
            temporary = file
        } catch { failed = true }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = continuation; self.continuation = nil
        let cancelled = cancelled; self.session = nil; self.task = nil; lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        guard let continuation else { return }
        if cancelled || failed || error != nil || (isDownload && temporary == nil) {
            if let temporary { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
            continuation.resume(throwing: cancelled ? CancellationError() : S3ObjectStoreError.unavailable)
        } else if let response = task.response as? HTTPURLResponse {
            continuation.resume(returning: Result(response: response, file: temporary))
        } else { continuation.resume(throwing: S3ObjectStoreError.unavailable) }
    }
}

enum S3LocalFile {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-s3-" + UUID().uuidString)
        guard mkdir(url.path, 0o700) == 0 else { throw S3ObjectStoreError.unavailable }
        return url
    }
    static func stage(_ source: URL, hash: String, count: Int64) async throws -> URL {
        let directory = try directory()
        do {
            let target = directory.appendingPathComponent("payload")
            try await export(source, destination: target, hash: hash, count: count)
            return target
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    static func export(_ source: URL, destination: URL, hash: String, count: Int64) async throws {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try copy(source, destination: destination, hash: hash, count: count) }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private static func copy(_ source: URL, destination: URL, hash: String, count: Int64) throws {
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL, !source.path.utf8.contains(0), !destination.path.utf8.contains(0) else {
            throw S3ObjectStoreError.invalid
        }
        let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw S3ObjectStoreError.invalid }
        defer { Darwin.close(input) }
        var initial = stat()
        guard fstat(input, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_size == count else {
            throw S3ObjectStoreError.integrity
        }
        let parent = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw S3ObjectStoreError.invalid }
        defer { Darwin.close(parent) }
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0) else { throw S3ObjectStoreError.invalid }
        let tempName = ".makosh-s3-" + UUID().uuidString
        let output = openat(parent, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw S3ObjectStoreError.unavailable }
        defer { Darwin.close(output); unlinkat(parent, tempName, 0) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1024 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        var digest = SHA256(); var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let size = Darwin.read(input, buffer, 1024 * 1024)
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw S3ObjectStoreError.unavailable }
            if size == 0 { break }
            total += Int64(size); guard total <= count else { throw S3ObjectStoreError.integrity }
            digest.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: size))
            var offset = 0
            while offset < size {
                try Task.checkCancellation()
                let written = Darwin.write(output, buffer.advanced(by: offset), size - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw S3ObjectStoreError.unavailable }; offset += written
            }
        }
        var final = stat()
        guard total == count, S3Signer.hex(digest.finalize()) == hash, fstat(input, &final) == 0,
              final.st_size == initial.st_size, final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else { throw S3ObjectStoreError.integrity }
        guard fsync(output) == 0 else { throw S3ObjectStoreError.unavailable }
        try Task.checkCancellation()
        guard renameatx_np(parent, tempName, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw S3ObjectStoreError.invalid }
    }
}

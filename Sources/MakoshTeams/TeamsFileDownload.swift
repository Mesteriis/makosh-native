import Foundation
import Darwin

protocol TeamsAddressResolving: Sendable { func addresses(for host: String) async throws -> [String] }

struct TeamsSystemAddressResolver: TeamsAddressResolving {
    func addresses(for host: String) async throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let first else { throw TeamsFailure.invalidResource }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
            cursor = current.pointee.ai_next
        }
        return addresses
    }
}

enum TeamsPublicAddress {
    static func accepts(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: v4) { publicV4(Array($0)) } }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 { return publicV4(Array(bytes.suffix(4))) }
        guard bytes[0] & 0xe0 == 0x20 else { return false } // Global unicast only; excludes loopback/link-local/ULA/multicast/NAT64.
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] & 0xfe == 0 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false }
        return true
    }
    private static func publicV4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = Int(bytes[0]), b = Int(bytes[1]), c = Int(bytes[2])
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) || a == 169 && b == 254 || a == 172 && (16...31).contains(b) { return false }
        if a == 192 && (b == 168 || b == 0 && (c == 0 || c == 2) || b == 88 && c == 99) { return false }
        if a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) || a == 203 && b == 0 && c == 113 { return false }
        return true
    }
}

struct TeamsFileDownloadResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let byteCount: Int64
    func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
}
protocol TeamsFileDownloading: Sendable {
    func download(_ request: URLRequest, to destination: URL, maximumBytes: Int64) async throws -> TeamsFileDownloadResponse
}

/// No automatic redirects. The caller follows at most one Graph-issued Location using a fresh credential-free request.
actor TeamsHTTPSFileDownloader: TeamsFileDownloading {
    private let configuration: URLSessionConfiguration
    private let resolver: any TeamsAddressResolving
    init(configuration: URLSessionConfiguration = .ephemeral, resolver: any TeamsAddressResolving = TeamsSystemAddressResolver()) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.httpCookieStorage = nil; copy.urlCredentialStorage = nil; copy.urlCache = nil
        copy.httpShouldSetCookies = false; copy.httpAdditionalHeaders = [:]; copy.connectionProxyDictionary = [:]
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData; copy.timeoutIntervalForRequest = 30; copy.timeoutIntervalForResource = 30
        self.configuration = copy; self.resolver = resolver
    }
    func download(_ request: URLRequest, to destination: URL, maximumBytes: Int64) async throws -> TeamsFileDownloadResponse {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https",
              let host = components.host, components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || components.port == 443, request.httpMethod == nil || request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Cookie") == nil, request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
              request.httpBody == nil, destination.isFileURL, (1...100 * 1024 * 1024).contains(maximumBytes) else { throw TeamsFailure.invalidResource }
        if request.value(forHTTPHeaderField: "Authorization") != nil, !TeamsGraphURL.accepts(url) { throw TeamsFailure.invalidResource }
        let addresses = try await resolver.addresses(for: host)
        try Task.checkCancellation()
        guard !addresses.isEmpty, addresses.allSatisfy(TeamsPublicAddress.accepts) else { throw TeamsFailure.invalidResource }
        var clean = request; clean.httpShouldHandleCookies = false; clean.timeoutInterval = 30
        clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let exchange = TeamsFileDownloadExchange(configuration: configuration, destination: destination, maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler { try await exchange.run(clean) } onCancel: { exchange.cancel() }
    }
}

private final class TeamsFileDownloadExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let destination: URL
    private let maximumBytes: Int64
    private var continuation: CheckedContinuation<TeamsFileDownloadResponse, any Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var fd: Int32 = -1
    private var created = false
    private var count: Int64 = 0
    private var cancelled = false
    init(configuration: URLSessionConfiguration, destination: URL, maximumBytes: Int64) {
        self.configuration = configuration; self.destination = destination; self.maximumBytes = maximumBytes
    }
    func run(_ request: URLRequest) async throws -> TeamsFileDownloadResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }
    func cancel() { lock.withLock { cancelled = true }; finish(.failure(CancellationError())) }
    private func headers(_ response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, pair in if let key = pair.key as? String { result[key] = String(describing: pair.value) } }
    }
    private func finish(_ result: Result<TeamsFileDownloadResponse, any Error>) {
        let work = lock.withLock { () -> (CheckedContinuation<TeamsFileDownloadResponse, any Error>, URLSession?, Bool)? in
            guard let continuation else { return nil }
            self.continuation = nil
            if fd >= 0 { Darwin.close(fd); fd = -1 }
            let active = session; session = nil
            let remove: Bool
            if case .failure = result { remove = created } else { remove = false }
            return (continuation, active, remove)
        }
        guard let work else { return }
        work.1?.invalidateAndCancel()
        if work.2 { _ = unlink(destination.path) }
        work.0.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.success(TeamsFileDownloadResponse(status: response.statusCode, headers: headers(response), byteCount: 0)))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { finish(.failure(TeamsFailure.invalidResponse)); completionHandler(.cancel); return }
        guard http.statusCode == 200 else { finish(.success(TeamsFileDownloadResponse(status: http.statusCode, headers: headers(http), byteCount: 0))); completionHandler(.cancel); return }
        guard response.expectedContentLength <= maximumBytes else { finish(.failure(TeamsFailure.bodyTooLarge)); completionHandler(.cancel); return }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" { finish(.failure(TeamsFailure.invalidResponse)); completionHandler(.cancel); return }
        let opened = lock.withLock { () -> Bool in
            guard continuation != nil else { return false }
            let parent = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { return false }
            defer { Darwin.close(parent) }
            var info = stat()
            guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return false }
            fd = openat(parent, destination.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return false }
            created = true; self.response = http; return true
        }
        if opened { completionHandler(.allow) } else { finish(.failure(TeamsFailure.storage)); completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let written = lock.withLock { () -> Bool in
            guard continuation != nil, fd >= 0, Int64(data.count) <= maximumBytes - count else { return false }
            let ok = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let size = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if size < 0 && errno == EINTR { continue }
                    guard size > 0 else { return false }; offset += size
                }
                return true
            }
            if ok { count += Int64(data.count) }; return ok
        }
        if !written { finish(.failure(TeamsFailure.bodyTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error != nil { finish(.failure(TeamsFailure.transport)); return }
        let result = lock.withLock { () -> TeamsFileDownloadResponse? in
            guard let response, fd >= 0, fsync(fd) == 0 else { return nil }
            return TeamsFileDownloadResponse(status: response.statusCode, headers: headers(response), byteCount: count)
        }
        if let result { finish(.success(result)) } else { finish(.failure(TeamsFailure.invalidResponse)) }
    }
}

import XCTest
@testable import MakoshTeams

final class TeamsDownloadRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func add(_ value: URLRequest) { lock.withLock { values.append(value) } }
    func reset() { lock.withLock { values.removeAll() } }
    func all() -> [URLRequest] { lock.withLock { values } }
}
final class TeamsDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    static let log = TeamsDownloadRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.log.add(request)
        let url = request.url!
        if url.host == "graph.microsoft.com" {
            let next = URL(string: "https://download.example.invalid/file")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": next.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "4"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("file".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
struct TeamsFixedResolver: TeamsAddressResolving {
    let addresses: [String]
    func addresses(for host: String) async throws -> [String] { addresses }
}

@MainActor
final class TeamsDownloadTransportTests: XCTestCase {
    func testDownloadRedirectNeverCarriesBearerOrCookies() async throws {
        TeamsDownloadURLProtocol.log.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamsDownloadURLProtocol.self]
        let transport = TeamsHTTPSFileDownloader(configuration: configuration, resolver: TeamsFixedResolver(addresses: ["8.8.8.8"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download")
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/drives/drive/items/item/content")!)
        request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        let first = try await transport.download(request, to: destination, maximumBytes: 100)
        XCTAssertEqual(first.status, 302)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let next = try XCTUnwrap(URL(string: try XCTUnwrap(first.headers["Location"])))
        let second = try await transport.download(URLRequest(url: next), to: destination, maximumBytes: 100)
        XCTAssertEqual(second.byteCount, 4)
        XCTAssertEqual(try Data(contentsOf: destination), Data("file".utf8))
        let requests = TeamsDownloadURLProtocol.log.all()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
    }
    func testPrivateAddressIsRejectedBeforeRequestOrPlaintextCreation() async throws {
        TeamsDownloadURLProtocol.log.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamsDownloadURLProtocol.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("must-not-exist")
        for address in ["127.0.0.1", "10.1.2.3", "192.168.1.4", "169.254.169.254", "::1", "fd00::1", "::ffff:127.0.0.1"] {
            let transport = TeamsHTTPSFileDownloader(configuration: configuration, resolver: TeamsFixedResolver(addresses: [address]))
            do { _ = try await transport.download(URLRequest(url: URL(string: "https://download.example.invalid/file")!), to: destination, maximumBytes: 100); XCTFail("Private target admitted") }
            catch let failure as TeamsFailure { XCTAssertEqual(failure, .invalidResource) }
        }
        XCTAssertTrue(TeamsDownloadURLProtocol.log.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

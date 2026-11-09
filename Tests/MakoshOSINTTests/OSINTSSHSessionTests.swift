import Foundation
import NIOCore
import NIOPosix
import XCTest

@testable import MakoshOSINT

final class OSINTSSHSessionTests: XCTestCase {
    private var server: OSINTSyntheticSSHServer?

    override func tearDown() async throws {
        if let server { try await within("server.stop") { await server.stop() } }
        server = nil
    }

    static let defaultScript: @Sendable (OSINTSyntheticSSHServer.Request) -> OSINTExecResult = { request in
        switch request.command {
        case "echo hi": OSINTExecResult(status: 0, stdout: "hi\n", stderr: "")
        case "false": OSINTExecResult(status: 1, stdout: "", stderr: "")
        case "warn": OSINTExecResult(status: 0, stdout: "out", stderr: "err")
        default: OSINTExecResult(status: 127, stdout: "", stderr: "unknown: \(request.command)\n")
        }
    }

    private func start(
        password: String = "pw-1", forwardPort: Int? = nil,
        script: @escaping @Sendable (OSINTSyntheticSSHServer.Request) -> OSINTExecResult = OSINTSSHSessionTests.defaultScript
    ) async throws -> (host: String, port: Int, fingerprint: String) {
        let server = OSINTSyntheticSSHServer(login: "makosh", password: password, script: script, forwardPort: forwardPort)
        self.server = server
        return try await server.start()
    }

    private func session(
        _ endpoint: (host: String, port: Int, fingerprint: String), password: String = "pw-1", expected: String? = nil
    )
        -> OSINTSSHSession
    {
        OSINTSSHSession(host: endpoint.host, port: endpoint.port, login: "makosh", password: { password }, expectedFingerprint: expected)
    }

    func testFirstConnectAsksForHostKeyAndReturnsFingerprint() async throws {
        let endpoint = try await start()
        let session = session(endpoint)
        let asked = Box<String?>(nil)
        let fingerprint = try await session.connect { offered in
            asked.value = offered
            return true
        }
        XCTAssertEqual(asked.value, fingerprint)
        XCTAssertEqual(fingerprint, endpoint.fingerprint)
        XCTAssertTrue(fingerprint.hasPrefix("SHA256:"), fingerprint)
        let connected = await session.isConnected
        XCTAssertTrue(connected)
        await session.close()
    }

    func testDeclinedHostKeyIsMismatch() async throws {
        let endpoint = try await start()
        let session = session(endpoint)
        do {
            _ = try await session.connect { _ in false }
            XCTFail("declined key must not connect")
        } catch { XCTAssertEqual(error as? OSINTFailure, .hostKeyMismatch, "\(error)") }
        let connected = await session.isConnected
        XCTAssertFalse(connected)
    }

    func testChangedHostKeyRefusesBeforeAuth() async throws {
        let endpoint = try await start()
        let first = session(endpoint)
        let trusted = try await first.connect { _ in true }
        await first.close()
        await server!.rotateHostKey()
        let second = session(endpoint, expected: trusted)
        do {
            _ = try await second.connect { _ in
                XCTFail("a pinned key is never asked about")
                return true
            }
            XCTFail("the key changed")
        } catch { XCTAssertEqual(error as? OSINTFailure, .hostKeyMismatch, "\(error)") }
        let requests = await server!.requests
        XCTAssertTrue(requests.isEmpty)
        let attempts = await server!.authenticationAttempts
        XCTAssertEqual(attempts, 1, "only the first session authenticated")
    }

    func testWrongPasswordIsAuthFailed() async throws {
        let endpoint = try await start()
        let session = session(endpoint, password: "wrong", expected: endpoint.fingerprint)
        do {
            _ = try await session.connect { _ in true }
            XCTFail("wrong password")
        } catch { XCTAssertEqual(error as? OSINTFailure, .sshAuthFailed, "\(error)") }
    }

    func testExecReturnsStatusAndStreams() async throws {
        let endpoint = try await start()
        let session = session(endpoint, expected: endpoint.fingerprint)
        _ = try await session.connect { _ in true }
        let ok = try await session.exec("echo hi")
        XCTAssertEqual(ok, OSINTExecResult(status: 0, stdout: "hi\n", stderr: ""))
        let failed = try await session.exec("false")
        XCTAssertEqual(failed.status, 1)
        let both = try await session.exec("warn")
        XCTAssertEqual(both, OSINTExecResult(status: 0, stdout: "out", stderr: "err"))
        let streamed = Box<[String]>([])
        _ = try await session.exec("echo hi", onOutput: { line in streamed.value.append(line) })
        XCTAssertEqual(streamed.value.joined(), "hi\n")
        let requests = await server!.requests
        XCTAssertEqual(requests.map(\.command), ["echo hi", "false", "warn", "echo hi"])
        await session.close()
    }

    func testExecStdinReachesServer() async throws {
        let endpoint = try await start()
        let session = session(endpoint, expected: endpoint.fingerprint)
        _ = try await session.connect { _ in true }
        let result = try await session.exec("install -m 600 /dev/stdin /opt/flowsint/.env", stdin: Data("AUTH_SECRET=x\n".utf8))
        XCTAssertEqual(result.status, 127, "the default script knows no install command, but it saw the stdin")
        let requests = await server!.requests
        XCTAssertEqual(
            requests.last,
            OSINTSyntheticSSHServer.Request(command: "install -m 600 /dev/stdin /opt/flowsint/.env", stdin: "AUTH_SECRET=x\n"))
        await session.close()
    }

    func testTunnelForwardsHTTP() async throws {
        let responder = try await within("responder.start") { try await FixedHTTPResponder.start(body: "pong") }
        defer { responder.stop() }
        let sshServer = OSINTSyntheticSSHServer(login: "makosh", password: "pw-1", script: Self.defaultScript, forwardPort: responder.port)
        server = sshServer
        let endpoint = try await within("server.start") { try await sshServer.start() }
        let session = session(endpoint, expected: endpoint.fingerprint)
        _ = try await within("connect") { try await session.connect { _ in true } }
        let tunnel = try await within("openTunnel") { try await session.openTunnel(toPort: 5173) }
        XCTAssertEqual(tunnel.baseURL.host, "127.0.0.1")
        XCTAssertNotEqual(tunnel.localPort, 0)
        let (data, response) = try await within("http") {
            try await URLSession.shared.data(from: tunnel.baseURL.appendingPathComponent("/ping"))
        }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pong")
        XCTAssertEqual(responder.requestCount, 1)
        try await within("tunnel.close") { await tunnel.close() }
        try await within("session.close") { await session.close() }
    }

    func testTunnelListensOnLoopbackOnly() async throws {
        let responder = try await FixedHTTPResponder.start(body: "pong")
        defer { responder.stop() }
        let endpoint = try await start(forwardPort: responder.port)
        let session = session(endpoint, expected: endpoint.fingerprint)
        _ = try await session.connect { _ in true }
        let tunnel = try await session.openTunnel(toPort: 5173)
        let loopback = await canConnect(host: "127.0.0.1", port: tunnel.localPort)
        XCTAssertTrue(loopback, "the port is bound on loopback")
        if let external = nonLoopbackIPv4Address() {
            let outside = await canConnect(host: external, port: tunnel.localPort)
            XCTAssertFalse(outside, "the port is not reachable through \(external)")
        }
        await session.close()
        let afterClose = await canConnect(host: "127.0.0.1", port: tunnel.localPort)
        XCTAssertFalse(afterClose, "closing the session closes the listener")
    }

    func testUnreachableHostIsSSHUnreachable() async throws {
        let probe = try await FixedHTTPResponder.start(body: "")
        let closedPort = probe.port
        probe.stop()
        let session = OSINTSSHSession(host: "127.0.0.1", port: closedPort, login: "makosh", password: { "x" }, expectedFingerprint: nil)
        do {
            _ = try await session.connect { _ in true }
            XCTFail("nothing listens there")
        } catch { XCTAssertEqual(error as? OSINTFailure, .sshUnreachable, "\(error)") }
    }

    // MARK: Helpers

    /// One TCP connect with a short timeout; false when nothing accepts there.
    private func canConnect(host: String, port: Int) async -> Bool {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        do {
            let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(2)).connect(host: host, port: port).get()
            try? await channel.close().get()
            return true
        } catch {
            return false
        }
    }

    /// An IPv4 address of a non-loopback interface, when the machine has one.
    private func nonLoopbackIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            return String(cString: host)
        }
        return nil
    }
}

/// Turns a hang into a failure naming the step.
func within<T: Sendable>(_ step: String, seconds: Double = 15, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(step: step)
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    var step: String
    var description: String { "timed out at \(step)" }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A loopback TCP listener answering every connection with one fixed HTTP/1.1 200 response.
final class FixedHTTPResponder: @unchecked Sendable {
    let port: Int
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup
    private let counter: Box<Int>
    var requestCount: Int { counter.value }

    private init(port: Int, channel: Channel, group: MultiThreadedEventLoopGroup, counter: Box<Int>) {
        self.port = port
        self.channel = channel
        self.group = group
        self.counter = counter
    }

    static func start(body: String) async throws -> FixedHTTPResponder {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let counter = Box<Int>(0)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Responder(body: body, counter: counter))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return FixedHTTPResponder(port: channel.localAddress!.port!, channel: channel, group: group, counter: counter)
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }

    private final class Responder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let body: String
        let counter: Box<Int>
        var buffered = ""
        init(body: String, counter: Box<Int>) {
            self.body = body
            self.counter = counter
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            buffered += bytes.readString(length: bytes.readableBytes) ?? ""
            guard buffered.contains("\r\n\r\n") else { return }
            counter.value += 1
            let response =
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            var out = context.channel.allocator.buffer(capacity: response.utf8.count)
            out.writeString(response)
            context.writeAndFlush(wrapOutboundOut(out)).whenComplete { _ in context.close(promise: nil) }
        }
    }
}

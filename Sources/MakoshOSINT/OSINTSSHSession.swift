import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

public struct OSINTExecResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Diagnostics to stderr when `MAKOSH_OSINT_SSH_TRACE` is set; never secrets.
enum OSINTTrace {
    private static let path = ProcessInfo.processInfo.environment["MAKOSH_OSINT_SSH_TRACE"]
    static let enabled = path != nil
    private static let lock = NSLock()
    static func log(_ message: @autoclosure () -> String) {
        guard let path else { return }
        let line = "[osint-ssh] \(message())\n"
        lock.withLock {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
            }
        }
    }
}

/// `SHA256:<base64>` of a host key, as OpenSSH prints it.
enum SSHFingerprint {
    static func of(_ key: NIOSSHPublicKey) -> String {
        let text = String(openSSHPublicKey: key)
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "SHA256:?" }
        let digest = Data(SHA256.hash(data: blob))
        return "SHA256:" + digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// One password SSH session to the OSINT server: host-key pinning, exec channels for the
/// installer and `direct-tcpip` tunnels for the API. Everything runs on the session's own event loop.
public actor OSINTSSHSession {
    public typealias Password = @Sendable () async throws -> String?

    private let host: String
    private let port: Int
    private let login: String
    private let password: Password
    private let expectedFingerprint: String?
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var tunnels: [OSINTTunnel] = []

    public init(host: String, port: Int, login: String, password: @escaping Password, expectedFingerprint: String?) {
        self.host = host
        self.port = port
        self.login = login
        self.password = password
        self.expectedFingerprint = expectedFingerprint
    }

    public var isConnected: Bool { channel?.isActive ?? false }
    /// The server's fingerprint seen by the last successful connect.
    public private(set) var fingerprint: String?

    /// Connects and authenticates. An unknown host key is offered to `onUnknownHostKey`; a pinned
    /// key that differs refuses before any authentication. Returns the server's fingerprint.
    public func connect(onUnknownHostKey: @escaping @Sendable (String) async -> Bool) async throws -> String {
        await close()
        guard let secret = try await password(), !secret.isEmpty else { throw OSINTFailure.sshAuthFailed }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let loop = group.next()
        let seen = NIOLockedValueBox<String?>(nil)
        let hostKeys = HostKeyDelegate(expected: expectedFingerprint, seen: seen, decide: onUnknownHostKey)
        let auth = PasswordDelegate(username: login, password: secret)
        let ready = loop.makePromise(of: Void.self)
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(SSHClientConfiguration(userAuthDelegate: auth, serverAuthDelegate: hostKeys)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    if OSINTTrace.enabled { try channel.pipeline.syncOperations.addHandler(TraceTap(side: "client")) }
                    try channel.pipeline.syncOperations.addHandlers([ssh, ReadinessHandler(ready: ready)])
                }
            }
        let channel: Channel
        OSINTTrace.log("connect start \(host):\(port)")
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
            OSINTTrace.log("tcp connected")
        } catch {
            OSINTTrace.log("tcp connect failed")
            ready.fail(error)
            await shutdownGroup()
            throw OSINTFailure.sshUnreachable
        }
        do {
            try await ready.futureResult.get()
            OSINTTrace.log("ready")
        } catch let failure as OSINTFailure {
            OSINTTrace.log("ready failed: \(failure.code)")
            try? await channel.close().get()
            await shutdownGroup()
            throw failure
        } catch {
            OSINTTrace.log("ready failed: \(type(of: error)) rejected=\(auth.wasRejected)")
            try? await channel.close().get()
            await shutdownGroup()
            throw auth.wasRejected ? OSINTFailure.sshAuthFailed : OSINTFailure.sshUnreachable
        }
        self.channel = channel
        let observed = seen.withLockedValue { $0 } ?? "SHA256:?"
        fingerprint = observed
        return observed
    }

    /// Runs one command; `stdin` is written and closed before the output is read.
    public func exec(
        _ command: String, stdin: Data? = nil, timeout: Duration = .seconds(60), onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> OSINTExecResult {
        guard let channel, channel.isActive else { throw OSINTFailure.sshUnreachable }
        let loop = channel.eventLoop
        let result = loop.makePromise(of: OSINTExecResult.self)
        let input = stdin.map { data -> ByteBuffer in
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            return buffer
        }
        loop.execute {
            let created = loop.makePromise(of: Channel.self)
            created.futureResult.whenFailure { _ in result.fail(OSINTFailure.unknownOutcome(stage: "exec")) }
            guard let handler = try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                created.fail(OSINTFailure.sshUnreachable)
                return
            }
            handler.createChannel(created, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(
                        ExecHandler(command: command, stdin: input, timeout: timeout, onOutput: onOutput, result: result))
                }
            }
        }
        return try await result.futureResult.get()
    }

    /// A loopback listener whose connections become `direct-tcpip` channels to `127.0.0.1:remotePort` on the server.
    public func openTunnel(toPort remotePort: Int) async throws -> OSINTTunnel {
        guard let channel, channel.isActive else { throw OSINTFailure.sshUnreachable }
        let loop = channel.eventLoop
        let ssh = channel
        let server = try await ServerBootstrap(group: loop, childGroup: loop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { inbound in
                let created = loop.makePromise(of: Channel.self)
                let origin = inbound.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0)) ?? inbound.localAddress!
                let target = SSHChannelType.DirectTCPIP(targetHost: "127.0.0.1", targetPort: remotePort, originatorAddress: origin)
                guard let handler = try? ssh.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                    return loop.makeFailedFuture(OSINTFailure.sshUnreachable)
                }
                handler.createChannel(created, channelType: .directTCPIP(target)) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        let (ours, theirs) = GlueHandler.matchedPair()
                        try child.pipeline.syncOperations.addHandlers([SSHDataCodec(), ours])
                        try inbound.pipeline.syncOperations.addHandler(theirs)
                    }
                }
                return created.futureResult.map { _ in }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let tunnel = OSINTTunnel(server: server)
        tunnels.append(tunnel)
        return tunnel
    }

    public func close() async {
        for tunnel in tunnels { await tunnel.close() }
        tunnels = []
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        await shutdownGroup()
    }

    private func shutdownGroup() async {
        guard let group else { return }
        self.group = nil
        OSINTTrace.log("group shutdown start")
        try? await group.shutdownGracefully()
        OSINTTrace.log("group shutdown done")
    }
}

// MARK: - Delegates and handlers

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let expected: String?
    let seen: NIOLockedValueBox<String?>
    let decide: @Sendable (String) async -> Bool

    init(expected: String?, seen: NIOLockedValueBox<String?>, decide: @escaping @Sendable (String) async -> Bool) {
        self.expected = expected
        self.seen = seen
        self.decide = decide
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = SSHFingerprint.of(hostKey)
        OSINTTrace.log("host key offered, pinned=\(expected != nil)")
        seen.withLockedValue { $0 = fingerprint }
        if let expected {
            if expected == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(OSINTFailure.hostKeyMismatch)
            }
            return
        }
        let decide = self.decide
        Task {
            if await decide(fingerprint) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(OSINTFailure.hostKeyMismatch)
            }
        }
    }
}

/// Offers the password once; a second request means the server rejected it.
private final class PasswordDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let lock = NIOLock()
    private var offer: NIOSSHUserAuthenticationOffer?
    private var rejected = false

    init(username: String, password: String) {
        offer = NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: password)))
    }

    var wasRejected: Bool { lock.withLock { rejected } }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let next: NIOSSHUserAuthenticationOffer? = lock.withLock {
            guard let offer, availableMethods.contains(.password) else {
                rejected = true
                return nil
            }
            self.offer = nil
            return offer
        }
        OSINTTrace.log("auth offer \(next == nil ? "none (rejected)" : "password")")
        // No offer left means the server rejected the password: failing the promise ends the connection
        // (succeeding with nil would leave it waiting forever).
        if let next { nextChallengePromise.succeed(next) } else { nextChallengePromise.fail(OSINTFailure.sshAuthFailed) }
    }
}

/// Completes `ready` when the server accepted the user, fails it on any error or early close.
private final class ReadinessHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private var ready: EventLoopPromise<Void>?
    init(ready: EventLoopPromise<Void>) { self.ready = ready }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        OSINTTrace.log("event \(type(of: event))")
        if event is UserAuthSuccessEvent {
            ready?.succeed(())
            ready = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        OSINTTrace.log("error \(type(of: error)): \(String(describing: error).prefix(120))")
        ready?.fail(error)
        ready = nil
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        OSINTTrace.log("inactive (ready pending=\(ready != nil))")
        ready?.fail(OSINTFailure.sshUnreachable)
        ready = nil
        context.fireChannelInactive()
    }
}

/// One `exec` on a session child channel: writes stdin, collects both streams and the exit status.
private final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let stdin: ByteBuffer?
    private let timeout: Duration
    private let onOutput: (@Sendable (String) -> Void)?
    private var result: EventLoopPromise<OSINTExecResult>?
    private var stdout = ""
    private var stderr = ""
    private var status: Int32?
    private var timer: Scheduled<Void>?

    init(
        command: String, stdin: ByteBuffer?, timeout: Duration, onOutput: (@Sendable (String) -> Void)?,
        result: EventLoopPromise<OSINTExecResult>
    ) {
        self.command = command
        self.stdin = stdin
        self.timeout = timeout
        self.onOutput = onOutput
        self.result = result
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [weak self] _ in self?.finish(nil) }
        if context.channel.isActive { start(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    private var started = false
    private func start(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        let amount = TimeAmount.nanoseconds(
            Int64(timeout.components.seconds) * 1_000_000_000 + Int64(timeout.components.attoseconds / 1_000_000_000))
        timer = context.eventLoop.scheduleTask(in: amount) { [weak self] in
            self?.result?.fail(OSINTFailure.unknownOutcome(stage: "exec"))
            self?.result = nil
            context.close(promise: nil)
        }
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(request).whenComplete { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .failure: self.finish(nil)
            case .success:
                if let stdin = self.stdin {
                    context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(stdin))), promise: nil)
                }
                context.close(mode: .output, promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = data.data else { return }
        let text = bytes.readString(length: bytes.readableBytes) ?? ""
        if data.type == .stdErr {
            stderr += text
        } else {
            stdout += text
            onOutput?(text)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus { status = Int32(truncatingIfNeeded: exit.exitStatus) }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(status)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        result?.fail(OSINTFailure.unknownOutcome(stage: "exec"))
        result = nil
        timer?.cancel()
        context.close(promise: nil)
    }

    private func finish(_ status: Int32?) {
        timer?.cancel()
        guard let result else { return }
        self.result = nil
        if let status {
            result.succeed(OSINTExecResult(status: status, stdout: stdout, stderr: stderr))
        } else {
            result.fail(OSINTFailure.unknownOutcome(stage: "exec"))
        }
    }
}

/// Byte counts of raw reads and writes when tracing is on.
final class TraceTap: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let side: String
    init(side: String) { self.side = side }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        OSINTTrace.log("\(side) read \(unwrapInboundIn(data).readableBytes) bytes")
        context.fireChannelRead(data)
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        OSINTTrace.log("\(side) write \(unwrapOutboundIn(data).readableBytes) bytes")
        context.write(data, promise: promise)
    }
    func flush(context: ChannelHandlerContext) {
        OSINTTrace.log("\(side) flush")
        context.flush()
    }
    func channelInactive(context: ChannelHandlerContext) {
        OSINTTrace.log("\(side) raw inactive")
        context.fireChannelInactive()
    }
}

/// `SSHChannelData` ⇄ `ByteBuffer` for tunnelled connections.
final class SSHDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in context.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = data.data, data.type == .channel else { return }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

/// Two handlers on two channels of one event loop that copy reads, flushes, EOF and closes to each other.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler(), second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.context?.write(data, promise: nil) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.context?.flush() }
    func channelInactive(context: ChannelHandlerContext) {
        // Flush what the partner still holds before taking it down with us.
        partner?.context?.flush()
        partner?.context?.close(promise: nil)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.context?.close(promise: nil)
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.context?.flush()
            partner?.context?.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.context?.channel.isWritable ?? false { context.read() } else { pendingRead = true }
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
}

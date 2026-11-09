import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// An SSH server on loopback for tests and QA: one login and password, scripted answers to
/// exec requests, optional `direct-tcpip` forwarding to one local port, a rotatable host key.
public actor OSINTSyntheticSSHServer {
    public struct Request: Equatable, Sendable {
        public var command: String
        public var stdin: String?
        public init(command: String, stdin: String? = nil) {
            self.command = command
            self.stdin = stdin
        }
    }

    public typealias Script = @Sendable (Request) -> OSINTExecResult

    private let login: String
    private let password: String
    private let script: Script
    private let forwardPort: Int?
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    private let shared = Shared()

    public init(login: String, password: String, script: @escaping Script, forwardPort: Int? = nil) {
        self.login = login
        self.password = password
        self.script = script
        self.forwardPort = forwardPort
    }

    public var requests: [Request] { shared.requests.withLockedValue { $0 } }
    public var authenticationAttempts: Int { shared.authAttempts.withLockedValue { $0 } }
    public var fingerprint: String { SSHFingerprint.of(hostKey.publicKey) }

    /// A new host key for the next connections: what a reinstalled server looks like to a client.
    public func rotateHostKey() {
        hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        shared.hostKey.withLockedValue { $0 = hostKey }
    }

    public func start() async throws -> (host: String, port: Int, fingerprint: String) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        shared.hostKey.withLockedValue { $0 = hostKey }
        let shared = self.shared
        let login = self.login, password = self.password, script = self.script, forwardPort = self.forwardPort
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let key = shared.hostKey.withLockedValue { $0 } ?? NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
                    let auth = ServerAuthDelegate(login: login, password: password, attempts: shared.authAttempts)
                    let ssh = NIOSSHHandler(
                        role: .server(SSHServerConfiguration(hostKeys: [key], userAuthDelegate: auth)), allocator: channel.allocator
                    ) { child, type in
                        switch type {
                        case .session:
                            return child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandler(ScriptedExecHandler(script: script, requests: shared.requests))
                            }
                        case .directTCPIP:
                            guard let forwardPort else { return child.eventLoop.makeFailedFuture(OSINTFailure.sshUnreachable) }
                            return child.eventLoop.makeCompletedFuture {
                                let (ours, theirs) = GlueHandler.matchedPair()
                                try child.pipeline.syncOperations.addHandlers([SSHDataCodec(), ours])
                                return theirs
                            }.flatMap { theirs in
                                ClientBootstrap(group: child.eventLoop).channelInitializer { target in
                                    target.eventLoop.makeCompletedFuture { try target.pipeline.syncOperations.addHandler(theirs) }
                                }.connect(host: "127.0.0.1", port: forwardPort).map { _ in }
                            }
                        case .forwardedTCPIP:
                            return child.eventLoop.makeFailedFuture(OSINTFailure.sshUnreachable)
                        }
                    }
                    if OSINTTrace.enabled { try channel.pipeline.syncOperations.addHandler(TraceTap(side: "server")) }
                    try channel.pipeline.syncOperations.addHandlers([ssh, SilentErrorHandler()])
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        self.channel = channel
        return ("127.0.0.1", channel.localAddress?.port ?? 0, fingerprint)
    }

    public func stop() async {
        if let channel { try? await channel.close().get() }
        channel = nil
        if let group { try? await group.shutdownGracefully() }
        group = nil
    }

    private final class Shared: Sendable {
        let requests = NIOLockedValueBox<[Request]>([])
        let authAttempts = NIOLockedValueBox<Int>(0)
        let hostKey = NIOLockedValueBox<NIOSSHPrivateKey?>(nil)
    }
}

private final class ServerAuthDelegate: NIOSSHServerUserAuthenticationDelegate, Sendable {
    let login: String
    let password: String
    let attempts: NIOLockedValueBox<Int>
    init(login: String, password: String, attempts: NIOLockedValueBox<Int>) {
        self.login = login
        self.password = password
        self.attempts = attempts
    }
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        attempts.withLockedValue { $0 += 1 }
        guard request.username == login, case .password(let offered) = request.request, offered.password == password else {
            OSINTTrace.log("server auth: failure")
            responsePromise.succeed(.failure)
            return
        }
        OSINTTrace.log("server auth: success")
        responsePromise.succeed(.success)
    }
}

private final class SilentErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        OSINTTrace.log("server error \(type(of: error)): \(String(describing: error).prefix(120))")
        context.close(promise: nil)
    }
}

/// Answers one exec request from the script after the client closed its stdin.
private final class ScriptedExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let script: OSINTSyntheticSSHServer.Script
    private let requests: NIOLockedValueBox<[OSINTSyntheticSSHServer.Request]>
    private var command: String?
    private var stdin = ""
    private var answered = false

    init(script: @escaping OSINTSyntheticSSHServer.Script, requests: NIOLockedValueBox<[OSINTSyntheticSSHServer.Request]>) {
        self.script = script
        self.requests = requests
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in context.fireErrorCaught(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exec as SSHChannelRequestEvent.ExecRequest:
            command = exec.command
            if exec.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        case let event as ChannelEvent:
            if case .inputClosed = event { answer(context: context) }
        default: break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = data.data else { return }
        stdin += bytes.readString(length: bytes.readableBytes) ?? ""
    }

    private func answer(context: ChannelHandlerContext) {
        guard !answered, let command else { return }
        answered = true
        let request = OSINTSyntheticSSHServer.Request(command: command, stdin: stdin.isEmpty ? nil : stdin)
        requests.withLockedValue { $0.append(request) }
        let result = script(request)
        if !result.stdout.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: result.stdout.utf8.count)
            buffer.writeString(result.stdout)
            context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        }
        if !result.stderr.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: result.stderr.utf8.count)
            buffer.writeString(result.stderr)
            context.write(wrapOutboundOut(SSHChannelData(type: .stdErr, data: .byteBuffer(buffer))), promise: nil)
        }
        context.flush()
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: Int(result.status))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

// Derived from MMail, copyright (c) 2026 moerdowo, MIT.
// Pinned source and retained notice: Dependencies/Mail.lock.json, Dependencies/Mail/MMail.MIT.notice.
// Makosh adaptations are recorded in docs/mail-migration.md.
import Foundation
import NIO
import NIOCore
import NIOPosix

struct SMTPResponse: Sendable {
    let code: Int
    let lines: [String]
    var ok: Bool { (200..<400).contains(code) }
}

// Parses SMTP replies (handles multi-line "250-foo\r\n250 bar\r\n").
final class SMTPResponseDecoder: ByteToMessageDecoder, @unchecked Sendable {
    typealias InboundOut = SMTPResponse
    private var pending: [String] = []
    private var pendingCode: Int?

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        var producedSomething = false
        while let crlf = buffer.readableBytesView.firstRange(of: [0x0D, 0x0A]) {
            let lineLength = crlf.lowerBound - buffer.readableBytesView.startIndex
            let lineBytes = buffer.readBytes(length: lineLength) ?? []
            buffer.moveReaderIndex(forwardBy: 2) // consume CRLF
            let line = String(decoding: lineBytes, as: UTF8.self)
            guard lineLength >= 4, lineLength <= 8192, pending.count < 1000,
                  let code = Int(line.prefix(3)), (100...599).contains(code),
                  pendingCode == nil || pendingCode == code else { throw MailError.noResult }
            let separator = line[line.index(line.startIndex,offsetBy:3)]
            guard separator == " " || separator == "-" else { throw MailError.noResult }
            pendingCode = code
            pending.append(line)
            // A final line has a space as the 4th character; a dash means more follow.
            if line.count >= 4 {
                let idx = line.index(line.startIndex, offsetBy: 3)
                if line[idx] == " " {
                    let code = Int(line.prefix(3)) ?? 0
                    context.fireChannelRead(wrapInboundOut(SMTPResponse(code: code, lines: pending)))
                    pending.removeAll(); pendingCode = nil
                    producedSomething = true
                }
            }
        }
        guard buffer.readableBytes <= 8192 else { throw MailError.noResult }
        return producedSomething ? .continue : .needMoreData
    }
}

final class SMTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SMTPResponse
    private var buffered: [SMTPResponse] = []
    private var waiters: [EventLoopPromise<SMTPResponse>] = []

    func await(promise: EventLoopPromise<SMTPResponse>) {
        if !buffered.isEmpty { promise.succeed(buffered.removeFirst()) }
        else { waiters.append(promise) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let resp = unwrapInboundIn(data)
        if !waiters.isEmpty { waiters.removeFirst().succeed(resp) }
        else { buffered.append(resp) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        waiters.forEach { $0.fail(error) }; waiters.removeAll(); context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        waiters.forEach { $0.fail(MailError.notConnected) }; waiters.removeAll(); context.fireChannelInactive()
    }
}

final class SMTPService: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let security: ConnectionSecurity
    private let username: String
    private let password: String
    private let tlsCAFile: String?

    private static let group = MultiThreadedEventLoopGroup.singleton
    private let handler = SMTPResponseHandler()
    private let connectionLock = NSLock()
    private var connection: Channel?
    private var channel: Channel? {
        get { connectionLock.lock(); defer { connectionLock.unlock() }; return connection }
        set { connectionLock.lock(); connection = newValue; connectionLock.unlock() }
    }
    private let admission = MailCommandDispatch()
    func cancel() { admission.cancel(); channel?.close(promise: nil) }

    init(config: MailAccountConfig, password: String, tlsCAFile: String? = nil) {
        self.tlsCAFile = tlsCAFile
        self.host = config.smtpHost
        self.port = config.smtpPort
        self.security = config.smtpSecurity
        self.username = config.smtpUsername
        self.password = password
    }

    /// Connects, authenticates, sends one message, and disconnects.
    /// `progress` reports the DATA upload fraction (0...1) for large messages.
    func send(from: String, fromName: String?, recipients: [String], message: String,
              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await performSend(from: from, fromName: fromName, recipients: recipients, message: message, progress: progress)
        } onCancel: { self.cancel() }
    }
    private func performSend(from: String, fromName: String?, recipients: [String], message: String,
                             progress: (@Sendable (Double) -> Void)?) async throws {
        try await connect()
        defer { Task { await self.close() } }

        _ = try await expect([220])                      // greeting
        try await ehlo()
        if security == .startTLS {
            _ = try await command("STARTTLS", expect: [220])
            guard let channel = self.channel else { throw MailError.notConnected }
            try await MailTLSHandler.install(channel: channel, host: host, caFile: tlsCAFile).get()
            try await ehlo()
        }
        try await authenticate()
        try Task.checkCancellation()

        _ = try await command("MAIL FROM:<\(from)>", expect: [250])
        for rcpt in recipients {
            _ = try await command("RCPT TO:<\(rcpt)>", expect: [250, 251])
        }
        _ = try await command("DATA", expect: [354])
        do { _ = try await sendData(message, progress: progress) }
        catch let error as MailFailure { if error == .serverRejected { throw error }; throw MailFailure.unknownSubmission }
        catch { throw MailFailure.unknownSubmission }
        // Acceptance is final even if QUIT cannot be acknowledged.
        await close()
    }

    // MARK: Connection

    private func connect() async throws {
        let bootstrap = ClientBootstrap(group: Self.group)
            .channelInitializer { [handler] channel in
                channel.pipeline.addHandlers([ByteToMessageHandler(SMTPResponseDecoder()), handler])
            }
        do {
            let channel = try await bootstrap.connectTimeout(.seconds(15)).connect(host: host, port: port).get()
            do { try admission.dispatch { self.channel = channel } }
            catch { channel.close(promise: nil); throw error }
            try Task.checkCancellation()
            if security == .tls { try await MailTLSHandler.install(channel: channel, host: host, caFile: tlsCAFile).get() }
        } catch {
            if error is CancellationError { throw error }
            throw MailError.connectFailed(error.localizedDescription)
        }
    }

    private func close() async {
        if let channel = self.channel { try? await channel.close().get() }
        self.channel = nil
    }

    private func ehlo() async throws {
        // Identify with the sender's domain rather than "localhost", which some
        // submission servers and spam filters penalize.
        let host = username.split(separator: "@").last.map(String.init) ?? "localhost"
        _ = try await command("EHLO \(host)", expect: [250])
    }

    private func authenticate() async throws {
        _ = try await command("AUTH LOGIN", expect: [334])
        _ = try await command(Data(username.utf8).base64EncodedString(), expect: [334])
        _ = try await command(Data(password.utf8).base64EncodedString(), expect: [235])
    }

    // MARK: Plumbing

    @discardableResult
    private func command(_ line: String, expect codes: [Int]) async throws -> SMTPResponse {
        try await writeLine(line + "\r\n")
        return try await expect(codes)
    }

    @discardableResult
    private func sendData(_ message: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> SMTPResponse {
        // Dot-stuff and terminate with <CRLF>.<CRLF>.
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
        let stuffed = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(".") ? "." + $0 : String($0) }
            .joined(separator: "\r\n")
        let payload = Array((stuffed + "\r\n.\r\n").utf8)
        guard let channel = self.channel else { throw MailError.notConnected }
        let total = payload.count
        let chunk = 64 * 1024
        var sent = 0
        while sent < total {
            try Task.checkCancellation()
            let end = Swift.min(sent + chunk, total)
            var buf = channel.allocator.buffer(capacity: end - sent)
            buf.writeBytes(payload[sent..<end])
            let chunk = buf
            try await channel.eventLoop.submit { [admission] in
                try admission.dispatch {
                    guard channel.isActive else { throw MailError.notConnected }
                    return channel.writeAndFlush(chunk)
                }
            }.flatMap { $0 }.get()
            sent = end
            progress?(Double(sent) / Double(total))
        }
        return try await expect([250])
    }

    private func writeLine(_ s: String) async throws {
        try Task.checkCancellation()
        guard let channel = self.channel else { throw MailError.notConnected }
        var buf = channel.allocator.buffer(capacity: s.utf8.count)
        buf.writeString(s)
        let line = buf
        try await channel.eventLoop.submit { [admission] in
            try admission.dispatch {
                guard channel.isActive else { throw MailError.notConnected }
                return channel.writeAndFlush(line)
            }
        }.flatMap { $0 }.get()
    }

    @discardableResult
    private func expect(_ codes: [Int]) async throws -> SMTPResponse {
        try Task.checkCancellation()
        guard let channel = self.channel else { throw MailError.notConnected }
        let promise = try await channel.eventLoop.submit { [handler] in
            guard channel.isActive else { throw MailError.notConnected }
            let promise = channel.eventLoop.makePromise(of: SMTPResponse.self)
            handler.await(promise: promise)
            return promise
        }.get()
        let deadline = channel.eventLoop.scheduleTask(in: .seconds(30)) { channel.close(promise:nil) }
        defer { deadline.cancel() }
        let resp = try await promise.futureResult.get()
        guard codes.contains(resp.code) else {
            if (400...599).contains(resp.code) { throw MailFailure.serverRejected }
            throw MailError.noResult
        }
        return resp
    }
}

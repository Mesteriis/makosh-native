import NIOCore
import CMailTLS

/// Confined to one NIO event loop. Certificate/hostname verification is mandatory.
final class MailTLSHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let host: String
    private let caFile: String?
    private var session: OpaquePointer?
    private var ready = false
    private var started = false
    private var completion: EventLoopPromise<Void>?
    private var timeout: Scheduled<Void>?
    init(host: String, caFile: String? = nil) { self.host = host; self.caFile = caFile }
    deinit { if let session { mail_tls_free(session) } }
    static func install(channel: Channel, host: String, caFile: String? = nil) -> EventLoopFuture<Void> {
        channel.eventLoop.flatSubmit {
            let handler = MailTLSHandler(host: host, caFile: caFile)
            let promise = channel.eventLoop.makePromise(of: Void.self)
            handler.completion = promise
            return channel.pipeline.addHandler(handler, position: .first).flatMap { promise.futureResult }
        }
    }
    func handlerAdded(context: ChannelHandlerContext) {
        session = host.withCString { hostname in
            if let caFile { return caFile.withCString { mail_tls_create(hostname,$0) } }
            return mail_tls_create(hostname,nil)
        }
        guard session != nil else { fail(context); return }
        timeout = context.eventLoop.scheduleTask(in: .seconds(20)) { [weak self, context] in self?.fail(context) }
        if context.channel.isActive { start(context) }
    }
    func channelActive(context: ChannelHandlerContext) { start(context); context.fireChannelActive() }
    private func start(_ context: ChannelHandlerContext) { guard !started else { return }; started = true; drive(context) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let session else { fail(context); return }
        let buffer = unwrapInboundIn(data)
        let result = buffer.withUnsafeReadableBytes { mail_tls_feed(session,$0.baseAddress,$0.count) }
        guard result == 1 else { fail(context); return }
        drive(context)
    }
    private func drive(_ context: ChannelHandlerContext) {
        guard let session else { return }
        if !ready {
            let status = mail_tls_handshake(session)
            guard status >= 0 else { fail(context); return }
            drain(context)
            if status == 1 { ready = true; timeout?.cancel(); completion?.succeed(()); completion = nil }
        }
        guard ready else { return }
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            var count = 0
            let status = mail_tls_decrypt(session,&bytes,bytes.count,&count)
            if count > 0 {
                var buffer = context.channel.allocator.buffer(capacity: count); buffer.writeBytes(bytes.prefix(count))
                context.fireChannelRead(wrapInboundOut(buffer))
            }
            if status < 0 { fail(context); return }
            if status == 0 || count == 0 { break }
        }
        drain(context)
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard ready, let session else { promise?.fail(MailError.notConnected); return }
        var buffer = unwrapOutboundIn(data)
        while buffer.readableBytes > 0 {
            var count = 0
            let status = buffer.withUnsafeReadableBytes { mail_tls_encrypt(session,$0.baseAddress,$0.count,&count) }
            guard status == 1, count > 0 else { promise?.fail(MailError.notConnected); fail(context); return }
            buffer.moveReaderIndex(forwardBy: count)
        }
        drain(context,promise: promise)
    }
    private func drain(_ context: ChannelHandlerContext,promise: EventLoopPromise<Void>? = nil) {
        guard let session else { promise?.fail(MailError.notConnected); return }
        var bytes = [UInt8](repeating: 0,count: 16384)
        var output = context.channel.allocator.buffer(capacity: 16384)
        while true {
            let count = mail_tls_drain(session,&bytes,bytes.count)
            guard count > 0 else { break }
            output.writeBytes(bytes.prefix(Int(count)))
        }
        if output.readableBytes > 0 { context.writeAndFlush(wrapOutboundOut(output),promise: promise) }
        else { promise?.succeed(()) }
    }
    private func fail(_ context: ChannelHandlerContext) {
        timeout?.cancel(); completion?.fail(MailError.connectFailed("TLS verification or handshake failed")); completion = nil
        context.fireErrorCaught(MailError.notConnected); context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        timeout?.cancel(); completion?.fail(MailError.notConnected); completion = nil
        context.fireChannelInactive()
    }
}

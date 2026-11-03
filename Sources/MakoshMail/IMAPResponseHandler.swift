// Derived from MMail, copyright (c) 2026 moerdowo, MIT.
// Pinned source and retained notice: Dependencies/Mail.lock.json, Dependencies/Mail/MMail.MIT.notice.
// Makosh adaptations are recorded in docs/mail-migration.md.
import Foundation
import NIO
import NIOCore
import NIOPosix
import NIOIMAP
import NIOIMAPCore

// Collects responses per command, matching the FIFO of issued tags.
final class IMAPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    private struct Pending {
        let tag: String
        let promise: EventLoopPromise<[Response]>
        var acc: [Response]
    }
    private var queue: [Pending] = []
    private var receivedBytes = 0
    private var idleStarted = false, idleStopRequested = false, idleEnding = false
    private var idleTag: String?
    func beginIdle(tag: String, promise: EventLoopPromise<[Response]>) {
        idleTag = tag
        idleStarted = false
        idleStopRequested = false
        idleEnding = false
        enqueue(tag: tag, promise: promise)
    }
    func stopIdle(channel: Channel) {
        guard idleTag != nil else { return }
        idleStopRequested = true
        if idleStarted && !idleEnding {
            idleEnding = true
            let endingTag = idleTag
            channel.writeAndFlush(IMAPClientHandler.Message.part(.idleDone), promise: nil)
            // A server that ignores DONE must not hold shutdown forever.
            channel.eventLoop.scheduleTask(in: .seconds(5)) { [weak self] in
                if self?.idleTag == endingTag { channel.close(promise: nil) }
            }
        }
    }
    func closeUnstartedIdle(channel: Channel) { if idleTag != nil && !idleStarted { channel.close(promise: nil) } }

    func enqueue(tag: String, promise: EventLoopPromise<[Response]>) {
        queue.append(Pending(tag: tag, promise: promise, acc: []))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        guard !queue.isEmpty else { return }  // greeting / unsolicited
        if case .fetch(.streamingBytes(let bytes)) = response { receivedBytes += bytes.readableBytes }
        guard receivedBytes <= 32 * 1024 * 1024, queue[0].acc.count < 200000 else {
            failAll(MailFailure.tooLarge)
            context.close(promise: nil)
            return
        }
        switch response {
        case .idleStarted:
            idleStarted = true
            queue[0].acc.append(response)
            if idleStopRequested { stopIdle(channel: context.channel) }
        case .tagged(let tagged):
            guard tagged.tag == queue[0].tag else {
                failAll(MailError.noResult)
                context.close(promise: nil)
                return
            }
            receivedBytes = 0
            var head = queue.removeFirst()
            if idleTag == tagged.tag { idleTag = nil }
            head.acc.append(response)
            head.promise.succeed(head.acc)
        case .fatal:
            failAll(MailError.notConnected)
            context.close(promise: nil)
        default:
            queue[0].acc.append(response)
            if idleTag != nil {
                switch response {
                case .untagged(.mailboxData), .fetch: stopIdle(channel: context.channel)
                default: break
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error)
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        failAll(MailError.notConnected)
        context.fireChannelInactive()
    }
    private func failAll(_ error: Error) {
        idleTag = nil
        let pending = queue
        queue.removeAll()
        pending.forEach { $0.promise.fail(error) }
    }
}

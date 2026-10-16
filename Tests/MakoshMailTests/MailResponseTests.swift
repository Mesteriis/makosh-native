import XCTest
import NIOCore
import NIOEmbedded
import NIOIMAPCore
@testable import MakoshMail
final class MailResponseTests: XCTestCase {
    func testMismatchedIMAPTagCannotAcknowledgeWrite() throws {
        let collector=IMAPResponseHandler();let channel=EmbeddedChannel(handler:collector)
        let promise=channel.eventLoop.makePromise(of:[Response].self)
        collector.enqueue(tag:"expected",promise:promise)
        try channel.writeInbound(Response.tagged(.init(tag:"other",state:.ok(.init(text:"accepted")))))
        XCTAssertThrowsError(try promise.futureResult.wait())
        _=try? channel.finish()
    }
    func testIMAPFatalFailsAllPendingRequests() throws {
        let collector=IMAPResponseHandler();let channel=EmbeddedChannel(handler:collector)
        let first=channel.eventLoop.makePromise(of:[Response].self),second=channel.eventLoop.makePromise(of:[Response].self)
        collector.enqueue(tag:"a",promise:first);collector.enqueue(tag:"b",promise:second)
        try channel.writeInbound(Response.fatal(.init(text:"closed")))
        XCTAssertThrowsError(try first.futureResult.wait())
        // Closing drains remaining operations, rather than retaining a stranded future.
        _ = try? channel.close().wait()
        XCTAssertThrowsError(try second.futureResult.wait())
    }
}

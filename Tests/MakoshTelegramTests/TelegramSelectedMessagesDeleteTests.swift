import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramSelectedMessagesDeleteTests: XCTestCase {
    private final class Lease: TelegramMessageActionsLease {
        var cancelled = 0
        func cancel() { cancelled += 1 }
    }
    private final class Provider: TelegramSelectedMessagesDeleteProvider {
        let accountID: Int64
        var callbacks: [@MainActor (TelegramMessageActionEvent) -> Void] = []
        var leases: [Lease] = []
        var synchronous: TelegramMessageActionEvent?
        init(accountID: Int64 = 1) { self.accountID = accountID }
        func start(request: TelegramSelectedMessagesDeleteRequest,
                   receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
            callbacks.append(receive); let lease = Lease(); leases.append(lease)
            if let synchronous { receive(synchronous) }
            return lease
        }
    }
    private func source(_ id: Int32, local: Bool = true, everyone: Bool = true, chat: Int64 = 7,
                        namespace: Int32 = 0, protected: Bool = false) -> TelegramMessageActionSource {
        .init(accountID: 1, chatID: chat, peerID: chat, namespace: namespace, messageID: id,
            fingerprint: "version", text: "synthetic", canReply: true, canEdit: false,
            canForward: !protected, canDeleteLocally: local, canDeleteForEveryone: everyone)
    }
    private func request(_ sources: [TelegramMessageActionSource], everyone: Bool = false) throws -> TelegramSelectedMessagesDeleteRequest {
        let selection = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(selection.begin(source: try XCTUnwrap(sources.first), contextID: context))
        for source in sources.dropFirst() {
            XCTAssertTrue(selection.toggle(source: source, sessionID: try XCTUnwrap(selection.session?.id), contextID: context))
        }
        return .init(session: try XCTUnwrap(selection.session), forEveryone: everyone)
    }
    func testPermissionIntersectionProtectionAndSavedEveryone() throws {
        XCTAssertTrue(telegramSelectedMessagesDeleteAllowed(try request([source(1, protected: true), source(2)])))
        XCTAssertFalse(telegramSelectedMessagesDeleteAllowed(try request([source(1), source(2, local: false)])))
        XCTAssertFalse(telegramSelectedMessagesDeleteAllowed(try request([source(1), source(2, everyone: false)], everyone: true)))
        XCTAssertFalse(telegramSelectedMessagesDeleteAllowed(try request([source(1, chat: 1)], everyone: true)))
        XCTAssertTrue(telegramSelectedMessagesDeleteAllowed(try request([source(1, chat: 1)])))
    }
    func testQueueAcknowledgementOnceAndSynchronousLeaseDisposed() throws {
        let c = TelegramSelectedMessagesDeleteController(), p = Provider(); p.synchronous = .queued
        let request = try request([source(1), source(2)])
        var ack: [TelegramSelectedMessagesDeleteRequest] = []; c.didQueue = { ack.append($0) }
        c.bind(provider: p); XCTAssertTrue(c.perform(request: request))
        XCTAssertEqual(c.phase, .queued); XCTAssertEqual(ack, [request]); XCTAssertEqual(p.leases[0].cancelled, 1)
        p.callbacks[0](.queued); XCTAssertEqual(ack.count, 1)
    }
    func testCancelTimeoutUncertaintyBlocksAutomaticRetryAndStaleBinding() throws {
        let c = TelegramSelectedMessagesDeleteController(), p = Provider(), request = try request([source(1)])
        c.bind(provider: p); XCTAssertTrue(c.perform(request: request)); c.cancel()
        XCTAssertEqual(c.phase, .uncertain); XCTAssertFalse(c.perform(request: request))
        p.callbacks[0](.queued); XCTAssertEqual(c.phase, .uncertain)
        let fresh = Provider(); c.bind(provider: fresh)
        XCTAssertTrue(c.perform(request: request)); p.callbacks[0](.rejected)
        XCTAssertEqual(c.phase, .validating); fresh.callbacks[0](.committing); c.timeout()
        XCTAssertEqual(c.phase, .uncertain); XCTAssertEqual(fresh.leases[0].cancelled, 1)
    }
    func testProvenRefusalPermitsNewExplicitAttemptButForeignAccountNeverDispatches() throws {
        let c = TelegramSelectedMessagesDeleteController(), p = Provider(), request = try request([source(1)])
        c.bind(provider: Provider(accountID: 2)); XCTAssertFalse(c.perform(request: request)); XCTAssertEqual(c.phase, .rejected)
        c.bind(provider: p); XCTAssertTrue(c.perform(request: request)); p.callbacks[0](.rejected)
        XCTAssertEqual(c.phase, .rejected); XCTAssertTrue(c.perform(request: request)); XCTAssertEqual(p.callbacks.count, 2)
    }
}

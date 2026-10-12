import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramMessageActionsControllerTests: XCTestCase {
    private final class Lease: TelegramMessageActionsLease {
        var cancellations = 0
        func cancel() { cancellations += 1 }
    }
    private final class Provider: TelegramMessageActionsProvider {
        let accountID: Int64
        var callbacks: [@MainActor (TelegramMessageActionEvent) -> Void] = []
        var leases: [Lease] = []
        var sources: [TelegramMessageActionSource] = []
        var actions: [TelegramMessageAction] = []
        var synchronous: [TelegramMessageActionEvent] = []
        init(accountID: Int64 = 1) { self.accountID = accountID }
        func start(action: TelegramMessageAction, source: TelegramMessageActionSource,
                   receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
            let lease = Lease(); leases.append(lease); callbacks.append(receive)
            sources.append(source); actions.append(action)
            for event in synchronous { receive(event) }
            return lease
        }
    }
    private func source(account: Int64 = 1, chat: Int64 = 10, peer: Int64 = 10, allowed: Bool = true) -> TelegramMessageActionSource {
        TelegramMessageActionSource(accountID: account, chatID: chat, peerID: peer, namespace: 0,
            messageID: 42, fingerprint: "frozen-version", text: "original", canReply: allowed,
            canEdit: allowed, canForward: allowed, canDeleteLocally: allowed, canDeleteForEveryone: allowed)
    }
    func testNoWorkUntilPerformAndFrozenTypedTargetOneOperation() {
        let controller = TelegramMessageActionsController(), provider = Provider()
        controller.bind(provider: provider)
        XCTAssertTrue(provider.actions.isEmpty)
        let original = source()
        XCTAssertTrue(controller.perform(.reply("caption"), source: original))
        XCTAssertFalse(controller.perform(.reply("second"), source: source(chat: 20,peer: 20)))
        XCTAssertEqual(provider.sources, [original]); XCTAssertEqual(provider.actions, [.reply("caption")])
        XCTAssertEqual(controller.phase, .validating)
        provider.callbacks[0](.committing)
        XCTAssertEqual(controller.phase, .committing)
        provider.callbacks[0](.queued)
        XCTAssertEqual(controller.phase, .queued)
        XCTAssertEqual(controller.source, original)
    }
    func testForeignAccountMismatchedChatAndDeniedCapabilitiesNeverCallProvider() {
        for action in [TelegramMessageAction.reply("x"), .edit("x"), .forward(destinationChatID: 30), .delete(forEveryone: false), .delete(forEveryone: true)] {
            for target in [source(account: 99),source(chat: 99),source(allowed: false)] {
                let controller = TelegramMessageActionsController(), provider = Provider()
                controller.bind(provider: provider)
                XCTAssertFalse(controller.perform(action,source: target))
                XCTAssertTrue(provider.actions.isEmpty)
            }
        }
    }
    func testPrecommitCancelAndTimeoutRejectStaleCallbacks() {
        for timeout in [false,true] {
            let controller = TelegramMessageActionsController(), provider = Provider()
            controller.bind(provider: provider)
            XCTAssertTrue(controller.perform(.edit("edited"),source: source()))
            if timeout { controller.timeout() } else { controller.cancel() }
            XCTAssertEqual(controller.phase,.rejected)
            XCTAssertEqual(provider.leases[0].cancellations,1)
            provider.callbacks[0](.committing); provider.callbacks[0](.applied)
            XCTAssertEqual(controller.phase,.rejected)
        }
    }
    func testPostcommitUncertaintyNeverRetriesAndLateAckBehavior() {
        let controller = TelegramMessageActionsController(), provider = Provider()
        controller.bind(provider: provider)
        XCTAssertTrue(controller.perform(.forward(destinationChatID: 30),source: source()))
        provider.callbacks[0](.committing); controller.timeout()
        XCTAssertEqual(controller.phase,.uncertain)
        XCTAssertFalse(controller.perform(.forward(destinationChatID: 30),source: source()))
        XCTAssertEqual(provider.actions.count,1)
        // The controller does not own a composer and cannot clear drafts or claim delivery.
        XCTAssertEqual(controller.action,.forward(destinationChatID: 30))
    }
    func testSameAccountRebindInvalidatesOldProviderAndKeepsNewTarget() {
        let controller = TelegramMessageActionsController(), old = Provider(), next = Provider()
        controller.bind(provider: old)
        XCTAssertTrue(controller.perform(.reply("old"),source: source()))
        old.callbacks[0](.committing)
        controller.bind(provider: next)
        old.callbacks[0](.queued)
        XCTAssertTrue(controller.perform(.reply("new"),source: source()))
        XCTAssertEqual(next.actions,[.reply("new")]); XCTAssertEqual(old.leases[0].cancellations,1)
        old.callbacks[0](.applied)
        XCTAssertEqual(controller.phase,.validating)
    }
    func testSynchronousTerminalCallbacksDisposeReturnedLeaseAndDuplicatesDoNotRevive() {
        for terminal in [TelegramMessageActionEvent.queued,.applied,.rejected,.uncertain] {
            let controller = TelegramMessageActionsController(), provider = Provider()
            provider.synchronous = [.committing,terminal]
            controller.bind(provider: provider)
            XCTAssertTrue(controller.perform(.reply("x"),source: source()))
            XCTAssertEqual(provider.leases[0].cancellations,1)
            let phase = controller.phase
            provider.callbacks[0](.committing); provider.callbacks[0](.queued)
            XCTAssertEqual(controller.phase,phase)
        }
    }
    func testQueueAcknowledgementOccursOnceForCapturedReplyAndNeverForStaleOrUncertain() {
        let controller = TelegramMessageActionsController(), provider = Provider()
        var acknowledgements: [(TelegramMessageAction, TelegramMessageActionSource)] = []
        controller.didQueue = { acknowledgements.append(($0,$1)) }
        controller.bind(provider: provider)
        let captured = source()
        XCTAssertTrue(controller.perform(.reply("frozen caption"),source: captured))
        provider.callbacks[0](.committing); controller.timeout()
        XCTAssertTrue(acknowledgements.isEmpty)
        provider.callbacks[0](.queued)
        XCTAssertTrue(acknowledgements.isEmpty)
        controller.bind(provider: provider)
        provider.synchronous = [.committing,.queued,.queued]
        XCTAssertTrue(controller.perform(.reply("new caption"),source: captured))
        XCTAssertEqual(acknowledgements.count,1)
        XCTAssertEqual(acknowledgements.first?.0,.reply("new caption"))
        XCTAssertEqual(acknowledgements.first?.1,captured)
        provider.callbacks[1](.queued); provider.callbacks[0](.queued)
        XCTAssertEqual(acknowledgements.count,1)
    }

    func testEditAdmissionRejectsIdenticalBytesAndOverLimitBeforeProvider() {
        let controller = TelegramMessageActionsController(), provider = Provider()
        controller.bind(provider: provider)
        XCTAssertFalse(controller.perform(.edit("original"),source: source()))
        XCTAssertFalse(controller.perform(.edit(String(repeating: "x",count: 4097)),source: source()))
        XCTAssertTrue(provider.actions.isEmpty)
        XCTAssertTrue(controller.perform(.edit(String(repeating: "x",count: 4096)),source: source()))
        XCTAssertEqual(provider.actions.count,1)
    }

    // Human confirmation may outlast a native-operation timeout. Once the
    // native operation starts, the same deadline must protect an unknown ACK.
    func testApprovalWaitOutlivesNativeDeadlineAndCommitRestartsIt() async throws {
        let controller = TelegramMessageActionsController(timeout: .milliseconds(20)), provider = Provider()
        provider.synchronous = [.awaitingApproval]
        controller.bind(provider: provider)
        XCTAssertTrue(controller.perform(.reply("Paid reply"), source: source()))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.phase, .validating)
        XCTAssertEqual(provider.leases[0].cancellations, 0)
        provider.callbacks[0](.committing)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.phase, .uncertain)
        XCTAssertEqual(provider.leases[0].cancellations, 1)
        XCTAssertEqual(controller.action, .reply("Paid reply"))
    }

}

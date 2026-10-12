import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramForwardControllerTests: XCTestCase {
    private final class Lease: TelegramComposerForwardLease { var cancelled = 0; func cancel() { cancelled += 1 } }
    private final class Provider: TelegramComposerForwardProvider {
        let accountID: Int64 = 1
        var resolves: [(@MainActor ([TelegramComposerForwardPreview]?) -> Void)] = []
        var events: [(@MainActor (TelegramComposerForwardEvent) -> Void)] = []
        var consumes: [(@MainActor (TelegramComposerDraft?) -> Void)] = []
        var leases: [Lease] = []
        var synchronous = false
        func resolve(draft: TelegramComposerDraft, completion: @escaping @MainActor ([TelegramComposerForwardPreview]?) -> Void) -> any TelegramComposerForwardLease {
            resolves.append(completion); let lease = Lease(); leases.append(lease)
            if synchronous { completion([]) }; return lease
        }
        func submit(draft: TelegramComposerDraft, receive: @escaping @MainActor (TelegramComposerForwardEvent) -> Void) -> any TelegramComposerForwardLease {
            events.append(receive); let lease = Lease(); leases.append(lease)
            if synchronous { receive(.accepted(.init(accountID: draft.accountID, chatID: draft.chatID, text: ""))) }; return lease
        }
        func consumeAccepted(draft: TelegramComposerDraft, completion: @escaping @MainActor (TelegramComposerDraft?) -> Void) -> any TelegramComposerForwardLease {
            consumes.append(completion); let lease = Lease(); leases.append(lease); return lease
        }
    }
    private func draft(text: String = "comment", disposition: TelegramComposerForwardDisposition = .prepared) -> TelegramComposerDraft {
        .init(accountID: 1, chatID: 42, text: text, forwardIntent: .init(sources: [.init(chatID: 7, peerID: 7, namespace: 0, messageID: 1, fingerprint: "version")]), forwardDisposition: disposition)
    }
    func testSynchronousResolutionAndAckDisposeReturnedLeasesOnce() {
        let provider = Provider(), controller = TelegramComposerForwardController(), value = draft()
        provider.synchronous = true; controller.bind(provider)
        var updates = 0; controller.didUpdateDraft = { from, to in XCTAssertEqual(from, value); XCTAssertNil(to.forwardIntent); updates += 1 }
        controller.select(value); XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(provider.leases[0].cancelled, 1)
        XCTAssertTrue(controller.submit(value)); XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(updates, 1); XCTAssertEqual(provider.leases[1].cancelled, 1)
        provider.events[0](.uncertain); XCTAssertEqual(controller.phase, .idle)
    }
    func testSameOperationInputUpdateDoesNotReloadAndStaleBindingCannotPublish() {
        let provider = Provider(), controller = TelegramComposerForwardController(), original = draft()
        controller.bind(provider); controller.select(original); provider.resolves[0]([])
        let changed = TelegramComposerDraft(accountID: 1, chatID: 42, text: "new comment", forwardIntent: original.forwardIntent)
        controller.select(changed); XCTAssertEqual(provider.resolves.count, 1)
        XCTAssertFalse(controller.submit(original)); XCTAssertTrue(controller.submit(changed))
        controller.bind(nil); provider.events[0](.accepted(.init(accountID: 1, chatID: 42, text: "")))
        XCTAssertEqual(controller.phase, .idle)
    }
    func testStartedNeverResendsAndAcceptedRecoveryOnlyConsumes() {
        let provider = Provider(), controller = TelegramComposerForwardController(), original = draft()
        controller.bind(provider)
        let started = TelegramComposerDraft(accountID: 1, chatID: 42, input: original.input, revision: original.revision, forwardIntent: original.forwardIntent, forwardDisposition: .submissionStarted)
        controller.select(started); XCTAssertEqual(controller.phase, .uncertain)
        XCTAssertFalse(controller.submit(started)); controller.retry(); XCTAssertTrue(provider.events.isEmpty)
        let accepted = TelegramComposerDraft(accountID: 1, chatID: 42, input: original.input, revision: original.revision, forwardIntent: original.forwardIntent,
            forwardDisposition: .accepted([.init(peerID: 42, namespace: 1, messageID: 1), .init(peerID: 42, namespace: 1, messageID: 2)]))
        controller.select(accepted); XCTAssertEqual(provider.consumes.count, 1)
        provider.consumes[0](nil); XCTAssertEqual(controller.phase, .uncertain)
        controller.retry(); XCTAssertEqual(provider.consumes.count, 2); XCTAssertTrue(provider.events.isEmpty)
        provider.consumes[1](.init(accountID: 1, chatID: 42, text: "")); XCTAssertEqual(controller.phase, .idle)
    }
    func testDurableReceiptFailureRetriesConsumptionOnly() {
        let provider = Provider(), controller = TelegramComposerForwardController(), original = draft()
        controller.bind(provider); controller.select(original); provider.resolves[0]([])
        var transitions: [TelegramComposerDraft] = []
        controller.didUpdateDraft = { _, to in transitions.append(to) }
        XCTAssertTrue(controller.submit(original))
        let started = TelegramComposerDraft(accountID: 1, chatID: 42, input: original.input, revision: original.revision,
            forwardIntent: original.forwardIntent, forwardDisposition: .submissionStarted)
        provider.events[0](.committing(started))
        let accepted = TelegramComposerDraft(accountID: 1, chatID: 42, input: original.input, revision: original.revision,
            forwardIntent: original.forwardIntent, forwardDisposition: .accepted([
                .init(peerID: 42, namespace: 1, messageID: 1), .init(peerID: 42, namespace: 1, messageID: 2)]))
        provider.events[0](.receiptAccepted(accepted)); provider.events[0](.uncertain)
        XCTAssertEqual(transitions, [started, accepted])
        controller.retry(); XCTAssertEqual(provider.events.count, 1); XCTAssertEqual(provider.consumes.count, 1)
        provider.consumes[0](.init(accountID: 1, chatID: 42, text: ""))
        XCTAssertEqual(controller.phase, .idle)
    }
    func testTimeoutAllowsLateAckButNeverAnotherSubmit() {
        let provider = Provider(), controller = TelegramComposerForwardController(), value = draft()
        controller.bind(provider); controller.select(value); provider.resolves[0]([])
        XCTAssertTrue(controller.submit(value)); controller.expire()
        XCTAssertEqual(controller.phase, .uncertain); XCTAssertFalse(controller.submit(value))
        provider.events[0](.accepted(.init(accountID: 1, chatID: 42, text: "")))
        XCTAssertEqual(controller.phase, .idle)
    }
    func testFailureRetryStaleResolutionAndForeignAccount() {
        let provider = Provider(), controller = TelegramComposerForwardController(), value = draft()
        controller.bind(provider); controller.select(value); provider.resolves[0](nil)
        XCTAssertEqual(controller.phase, .unavailable); controller.retry(); XCTAssertEqual(provider.resolves.count, 2)
        provider.resolves[0]([]); XCTAssertEqual(controller.phase, .loading)
        provider.resolves[1]([]); XCTAssertEqual(controller.phase, .ready)
        controller.select(.init(accountID: 2, chatID: 42, text: "", forwardIntent: value.forwardIntent))
        XCTAssertEqual(controller.phase, .idle)
    }
    func testApprovalWaitOutlivesDeadlineAndConsentRestartsNativeDeadline() async throws {
        let provider = Provider(), controller = TelegramComposerForwardController(timeout: .milliseconds(40)), value = draft()
        controller.bind(provider); controller.select(value); provider.resolves[0]([])
        XCTAssertTrue(controller.submit(value)); provider.events[0](.awaitingApproval)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.phase, .committing); XCTAssertNil(controller.error)
        XCTAssertEqual(provider.leases.last?.cancelled, 0)
        provider.events[0](.approvalCompleted)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.phase == .committing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.phase, .uncertain); XCTAssertFalse(controller.submit(value))
        provider.events[0](.accepted(.init(accountID: 1, chatID: 42, text: "")))
        XCTAssertEqual(controller.phase, .idle)
    }
    func testRejectedApprovalReleasesWaitingLeaseWithoutChangingDraft() async throws {
        let provider = Provider(), controller = TelegramComposerForwardController(timeout: .milliseconds(40)), value = draft()
        controller.bind(provider); controller.select(value); provider.resolves[0]([])
        var updates: [TelegramComposerDraft] = []; controller.didUpdateDraft = { _, value in updates.append(value) }
        XCTAssertTrue(controller.submit(value)); provider.events[0](.awaitingApproval)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.phase, .committing)
        provider.events[0](.rejected(value))
        XCTAssertEqual(controller.phase, .unavailable); XCTAssertEqual(updates, [value])
        XCTAssertEqual(provider.leases.last?.cancelled, 1)
    }
    func testCancelWhileWaitingInvalidatesLateApprovalAndAcceptance() async throws {
        let provider = Provider(), controller = TelegramComposerForwardController(timeout: .milliseconds(40)), value = draft()
        controller.bind(provider); controller.select(value); provider.resolves[0]([])
        XCTAssertTrue(controller.submit(value)); provider.events[0](.awaitingApproval)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.phase, .committing)
        controller.cancel(); XCTAssertEqual(controller.phase, .idle)
        provider.events[0](.approvalCompleted)
        provider.events[0](.accepted(.init(accountID: 1, chatID: 42, text: "")))
        XCTAssertEqual(controller.phase, .idle); XCTAssertEqual(provider.leases.last?.cancelled, 1)
    }
}

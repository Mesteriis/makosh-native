import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramSavedMessagesForwardControllerTests: XCTestCase {
    private final class Lease: TelegramComposerForwardLease {
        var cancelled = 0
        func cancel() { cancelled += 1 }
    }
    private final class Provider: TelegramSavedMessagesForwardProvider {
        let accountID: Int64 = 1
        var restored: TelegramSavedMessagesForwardRecord?
        var holdRecovery = false
        var synchronous = false
        var recovery: (@MainActor (Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>) -> Void)?
        var events: [@MainActor (TelegramMessageActionEvent) -> Void] = []
        var leases: [Lease] = []
        func recover(completion: @escaping @MainActor (Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>) -> Void) -> any TelegramComposerForwardLease {
            recovery = completion; let lease = Lease(); leases.append(lease)
            if !holdRecovery { completion(.success(restored)) }; return lease
        }
        func submit(request: TelegramSavedMessagesForwardRequest, receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramComposerForwardLease {
            events.append(receive); let lease = Lease(); leases.append(lease)
            if synchronous { receive(.committing); receive(.queued) }; return lease
        }
    }
    private func request(accountID: Int64 = 1, count: Int = 2) -> TelegramSavedMessagesForwardRequest {
        .init(contextID: UUID(), accountID: accountID, sources: (1...count).map {
            .init(chatID: 7, peerID: 7, namespace: 0, messageID: Int32($0), fingerprint: "source\($0)")
        })
    }
    func testExplicitSynchronousSubmissionDisposesLeasesAndNeverRepeatsSameRequest() {
        let provider = Provider(), controller = TelegramSavedMessagesForwardController(), value = request()
        provider.synchronous = true; controller.bind(provider)
        XCTAssertEqual(controller.phase, .idle); XCTAssertEqual(provider.leases[0].cancelled, 1)
        var queued = 0; controller.didQueue = { XCTAssertEqual($0, value); queued += 1 }
        XCTAssertTrue(controller.perform(value)); XCTAssertEqual(controller.phase, .queued)
        XCTAssertEqual(queued, 1); XCTAssertEqual(provider.leases[1].cancelled, 1)
        provider.events[0](.queued); XCTAssertEqual(queued, 1)
        XCTAssertFalse(controller.perform(value)); XCTAssertEqual(provider.events.count, 1)
    }
    func testCancellationAndTimeoutPreserveUnknownOutcomeAndRejectLateAck() {
        for timeout in [false, true] {
            let provider = Provider(), controller = TelegramSavedMessagesForwardController()
            controller.bind(provider); XCTAssertTrue(controller.perform(request()))
            provider.events[0](.committing)
            if timeout { controller.timeout() } else { controller.cancel() }
            XCTAssertEqual(controller.phase, .uncertain); XCTAssertFalse(controller.perform(request()))
            provider.events[0](.queued); XCTAssertEqual(controller.phase, .uncertain)
            XCTAssertEqual(provider.leases.last?.cancelled, 1)
        }
    }
    func testRecoveryNeverSubmitsAndDistinguishesStartedAcceptedAndUnknownBytes() {
        for accepted in [false, true] {
            let provider = Provider(), controller = TelegramSavedMessagesForwardController(), value = request()
            provider.restored = .init(request: value, acceptedIDs: accepted ? [.init(peerID: 1, namespace: 1, messageID: 1), .init(peerID: 1, namespace: 1, messageID: 2)] : nil)
            var recovered: [TelegramSavedMessagesForwardRequest] = []
            controller.didRecoverAcceptance = {
                XCTAssertEqual(controller.phase, .validating, "Reconcile before releasing the recovery lock")
                recovered.append($0)
            }
            controller.bind(provider); XCTAssertEqual(controller.phase, accepted ? .queued : .uncertain)
            XCTAssertEqual(recovered, accepted ? [value] : [])
            XCTAssertEqual(controller.requestID, value.id); XCTAssertTrue(provider.events.isEmpty)
        }
        let provider = Provider(), controller = TelegramSavedMessagesForwardController()
        provider.holdRecovery = true; controller.bind(provider); provider.recovery?(.failure(.incompatibleData))
        XCTAssertEqual(controller.phase, .uncertain); XCTAssertNotNil(controller.error); XCTAssertTrue(provider.events.isEmpty)
    }
    func testStaleRecoveryAndForeignScopeCannotPublishOrSubmit() {
        let provider = Provider(), controller = TelegramSavedMessagesForwardController()
        provider.holdRecovery = true; controller.bind(provider); controller.bind(nil)
        provider.recovery?(.success(.init(request: request())))
        XCTAssertEqual(controller.phase, .idle); XCTAssertNil(controller.requestID)
        provider.holdRecovery = false; controller.bind(provider)
        XCTAssertFalse(controller.perform(request(accountID: 2)))
        XCTAssertFalse(controller.perform(request(count: 101))); XCTAssertTrue(provider.events.isEmpty)
    }
    func testExplicitZeroQueueRejectionCanBeRetriedWithNewIntent() {
        let provider = Provider(), controller = TelegramSavedMessagesForwardController()
        controller.bind(provider); XCTAssertTrue(controller.perform(request())); provider.events[0](.rejected)
        XCTAssertEqual(controller.phase, .rejected); XCTAssertTrue(controller.perform(request()))
        XCTAssertEqual(provider.events.count, 2)
    }
    func testApprovalWaitOutlivesDeadlineAndConsentRestartsNativeDeadline() async throws {
        let provider = Provider(), controller = TelegramSavedMessagesForwardController(timeout: .milliseconds(40))
        controller.bind(provider); XCTAssertTrue(controller.perform(request()))
        provider.events[0](.awaitingApproval)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.phase, .validating); XCTAssertTrue(controller.isBusy)
        XCTAssertEqual(provider.leases.last?.cancelled, 0)
        provider.events[0](.committing)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.phase == .committing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.phase, .uncertain); XCTAssertEqual(provider.leases.last?.cancelled, 1)
        provider.events[0](.queued); XCTAssertEqual(controller.phase, .uncertain)
    }
    func testRejectedApprovalReleasesWaitingLeaseWithoutQueueReceipt() async throws {
        let provider = Provider(), controller = TelegramSavedMessagesForwardController(timeout: .milliseconds(40))
        controller.bind(provider); XCTAssertTrue(controller.perform(request()))
        var queued = 0; controller.didQueue = { _ in queued += 1 }
        provider.events[0](.awaitingApproval)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.phase, .validating)
        provider.events[0](.rejected)
        XCTAssertEqual(controller.phase, .rejected); XCTAssertEqual(queued, 0)
        XCTAssertEqual(provider.leases.last?.cancelled, 1)
    }
    func testCancelBeforeConsentIsKnownRejectionAndLateApprovalCannotQueue() {
        let provider = Provider(), controller = TelegramSavedMessagesForwardController(timeout: .milliseconds(40))
        controller.bind(provider); XCTAssertTrue(controller.perform(request()))
        var queued = 0; controller.didQueue = { _ in queued += 1 }
        provider.events[0](.awaitingApproval); controller.cancel()
        XCTAssertEqual(controller.phase, .rejected)
        provider.events[0](.committing); provider.events[0](.queued)
        XCTAssertEqual(controller.phase, .rejected); XCTAssertEqual(queued, 0)
        XCTAssertEqual(provider.leases.last?.cancelled, 1)
        XCTAssertTrue(controller.perform(request()))
    }
}

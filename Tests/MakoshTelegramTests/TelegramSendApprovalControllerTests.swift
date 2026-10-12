import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor private final class ApprovalProvider: TelegramSendApprovalProviding {
    var capabilityRequests: [TelegramSendContext] = []
    var confirmations: [(TelegramSendContext, Int64, UUID)] = []
    var capabilityCallbacks: [(Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>) -> Void] = []
    var consentCallbacks: [(Result<TelegramPaidSendConsent, TelegramPaidSendConsentError>) -> Void] = []
    var disposedCapabilities = 0
    var disposedConfirmations = 0
    var immediateFee: TelegramMessageFee?

    func capabilities(context: TelegramSendContext) -> Signal<Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>, NoError> {
        capabilityRequests.append(context)
        if let immediateFee { return .single(.success(approvalCapabilities(context, fee: immediateFee))) }
        return Signal { subscriber in
            self.capabilityCallbacks.append { subscriber.putNext($0) }
            return ActionDisposable { MainActor.assumeIsolated { self.disposedCapabilities += 1 } }
        }
    }
    func createConsent(context: TelegramSendContext, perMessageStars: Int64, consentID: UUID) -> Signal<Result<TelegramPaidSendConsent, TelegramPaidSendConsentError>, NoError> {
        confirmations.append((context, perMessageStars, consentID))
        return Signal { subscriber in
            self.consentCallbacks.append { subscriber.putNext($0) }
            return ActionDisposable { MainActor.assumeIsolated { self.disposedConfirmations += 1 } }
        }
    }
}

@MainActor private final class ApprovalClock {
    var actions: [@MainActor () -> Void] = []
    var disposed = 0
    func schedule(_ action: @escaping @MainActor () -> Void) -> Disposable {
        actions.append(action)
        return ActionDisposable { MainActor.assumeIsolated { self.disposed += 1 } }
    }
}

private nonisolated func approvalContext(account: Int64 = 1, count: Int = 2) -> TelegramSendContext {
    .init(accountID: account, chatID: 42, threadID: nil, submissionRevision: UUID(), messageCount: count)
}
private nonisolated func approvalCapabilities(_ context: TelegramSendContext,
    fee: TelegramMessageFee = .stars(7)) -> TelegramConversationCapabilities {
    .init(accountID: context.accountID, chatID: context.chatID, messageFee: fee, secret: nil)
}
private nonisolated func approvalConsent(_ prompt: TelegramSendApprovalPrompt) -> TelegramPaidSendConsent {
    .init(id: prompt.id, context: prompt.context, perMessageStars: 7, totalStars: 14)
}

@MainActor final class TelegramSendApprovalControllerTests: XCTestCase {
    private func setup() -> (TelegramSendApprovalController, ApprovalProvider, ApprovalClock) {
        let provider = ApprovalProvider(), clock = ApprovalClock()
        let controller = TelegramSendApprovalController(scheduleDeadline: clock.schedule)
        controller.bind(provider: provider, accountID: 1)
        return (controller, provider, clock)
    }
    private func paid(_ controller: TelegramSendApprovalController, _ provider: ApprovalProvider,
        context: TelegramSendContext = approvalContext(), completion: @escaping (Result<TelegramPaidSendConsent?, TelegramSendApprovalError>) -> Void)
        -> TelegramSendApprovalPrompt? {
        controller.request(context: context, title: "Synthetic participant", completion: completion)
        guard provider.capabilityCallbacks.count == 1 else { XCTFail("Current capability request was not started"); return nil }
        provider.capabilityCallbacks[0](.success(approvalCapabilities(context)))
        guard let prompt = controller.pendingPrompt else { XCTFail("Paid request did not publish a prompt"); return nil }
        return prompt
    }

    // No binding, foreign account or invalid count must reach native providers.
    func testUnboundMismatchedAndInvalidRequestsNeverLoadOrCreateConsent() {
        let (controller, provider, _) = setup()
        for context in [approvalContext(account: 2), approvalContext(count: 0), approvalContext(count: 101)] {
            var result: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>?
            controller.request(context: context, title: "Synthetic", completion: { result = $0 })
            XCTAssertEqual(result, .failure(.incompatible))
        }
        controller.dispose()
        var result: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>?
        controller.request(context: approvalContext(), title: "Synthetic", completion: { result = $0 })
        XCTAssertEqual(result, .failure(.unavailable))
        XCTAssertTrue(provider.capabilityRequests.isEmpty); XCTAssertTrue(provider.confirmations.isEmpty)
    }

    // Synchronous free results complete once without creating a confirmation.
    func testFreeCompletesOnceAndLeavesNoPromptOrNativeWrite() {
        let (controller, provider, clock) = setup(); provider.immediateFee = .free
        var results: [Result<TelegramPaidSendConsent?, TelegramSendApprovalError>] = []
        controller.request(context: approvalContext(), title: "Synthetic", completion: { results.append($0) })
        XCTAssertEqual(results, [.success(nil)])
        XCTAssertNil(controller.pendingPrompt); XCTAssertFalse(controller.isConfirming)
        XCTAssertTrue(provider.confirmations.isEmpty)
        for action in clock.actions { action() }
        XCTAssertEqual(results, [.success(nil)])
    }

    // Price/count/total and revision are immutable; loading does not authorize.
    func testPaidPromptCarriesExactImmutableContextWithoutCreatingConsent() {
        let (controller, provider, clock) = setup(), context = approvalContext()
        var result: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>?
        guard let prompt = paid(controller, provider, context: context, completion: { result = $0 }) else { return }
        XCTAssertEqual(prompt.context, context); XCTAssertEqual(prompt.title, "Synthetic participant")
        XCTAssertEqual(prompt.perMessageStars, 7); XCTAssertEqual(prompt.totalStars, 14)
        XCTAssertNil(result); XCTAssertTrue(provider.confirmations.isEmpty)
        for action in clock.actions { action() }
        XCTAssertEqual(controller.pendingPrompt, prompt); XCTAssertNil(result)
    }

    // Only the currently displayed prompt can invoke the durable native create.
    func testExactConfirmationCreatesOnceAndReturnsOnlyMatchingConsent() {
        let (controller, provider, _) = setup()
        var results: [Result<TelegramPaidSendConsent?, TelegramSendApprovalError>] = []
        controller.confirm(promptID: UUID())
        guard let prompt = paid(controller, provider, completion: { results.append($0) }) else { return }
        controller.confirm(promptID: UUID()); XCTAssertTrue(provider.confirmations.isEmpty)
        controller.confirm(promptID: prompt.id); controller.confirm(promptID: prompt.id)
        XCTAssertEqual(provider.confirmations.count, 1); XCTAssertTrue(controller.isConfirming)
        guard let request = provider.confirmations.first else { return }
        XCTAssertEqual(request.0, prompt.context); XCTAssertEqual(request.1, 7); XCTAssertEqual(request.2, prompt.id)
        provider.consentCallbacks[0](.success(approvalConsent(prompt)))
        XCTAssertEqual(results, [.success(approvalConsent(prompt))])
        XCTAssertNil(controller.pendingPrompt); XCTAssertFalse(controller.isConfirming)
        controller.confirm(promptID: prompt.id); XCTAssertEqual(provider.confirmations.count, 1)
    }

    // Native current-price failure cannot return approval or silently re-price.
    func testChangedFeeAndForeignConsentFailClosedAndClearPrompt() {
        for foreign in [false, true] {
            let (controller, provider, _) = setup()
            var result: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>?
            guard let prompt = paid(controller, provider, completion: { result = $0 }) else { continue }
            controller.confirm(promptID: prompt.id)
            if foreign {
                provider.consentCallbacks[0](.success(.init(id: UUID(), context: prompt.context, perMessageStars: 7, totalStars: 14)))
                XCTAssertEqual(result, .failure(.incompatible))
            } else {
                provider.consentCallbacks[0](.failure(.stale))
                XCTAssertEqual(result, .failure(.stale))
            }
            XCTAssertNil(controller.pendingPrompt); XCTAssertFalse(controller.isConfirming)
        }
    }

    // Cancelled or rebound operations must never deliver late approval to enqueue.
    func testCancelAndRebindDisposeNativeLeaseAndIgnoreLateConfirmation() {
        let (controller, provider, _) = setup()
        var results: [Result<TelegramPaidSendConsent?, TelegramSendApprovalError>] = []
        guard let prompt = paid(controller, provider, completion: { results.append($0) }) else { return }
        controller.confirm(promptID: prompt.id)
        controller.bind(provider: ApprovalProvider(), accountID: 2)
        XCTAssertEqual(results, [.failure(.cancelled)]); XCTAssertEqual(provider.disposedConfirmations, 1)
        provider.consentCallbacks[0](.success(approvalConsent(prompt)))
        XCTAssertEqual(results, [.failure(.cancelled)]); XCTAssertNil(controller.pendingPrompt)
    }

    // A delayed capability result must not publish a prompt for an old account.
    func testRebindDuringLoadIgnoresOldCapabilityAndKeepsNewRequest() {
        let (controller, provider, _) = setup(), old = approvalContext()
        var results: [Result<TelegramPaidSendConsent?, TelegramSendApprovalError>] = []
        controller.request(context: old, title: "Old", completion: { results.append($0) })
        guard provider.capabilityCallbacks.count == 1 else { return XCTFail("No first native load") }
        let current = ApprovalProvider()
        controller.bind(provider: current, accountID: 2)
        let next = approvalContext(account: 2)
        controller.request(context: next, title: "New", completion: { results.append($0) })
        provider.capabilityCallbacks[0](.success(approvalCapabilities(old)))
        XCTAssertNil(controller.pendingPrompt); XCTAssertEqual(provider.disposedCapabilities, 1)
        guard current.capabilityCallbacks.count == 1 else { return XCTFail("No current native load") }
        current.capabilityCallbacks[0](.success(approvalCapabilities(next)))
        XCTAssertEqual(controller.pendingPrompt?.context, next)
        XCTAssertEqual(results, [.failure(.cancelled)])
    }

    // The same pending prompt remains when a second request is rejected busy.
    func testBusyAndStaleCancelCannotReplaceCurrentPrompt() {
        let (controller, provider, _) = setup()
        var first: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>?
        guard let prompt = paid(controller, provider, completion: { first = $0 }) else { return }
        var second: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>?
        controller.request(context: approvalContext(), title: "Other", completion: { second = $0 })
        XCTAssertEqual(second, .failure(.busy)); XCTAssertEqual(controller.pendingPrompt, prompt)
        controller.cancel(promptID: UUID()); XCTAssertNil(first)
        controller.cancel(promptID: prompt.id)
        XCTAssertEqual(first, .failure(.cancelled)); XCTAssertNil(controller.pendingPrompt)
        controller.confirm(promptID: prompt.id); XCTAssertTrue(provider.confirmations.isEmpty)
    }

    // Native phase deadlines finish once and cannot be revived by a late callback.
    func testLoadAndConfirmationDeadlinesIgnoreLateResults() {
        let (loading, loadProvider, loadClock) = setup(), context = approvalContext()
        var loadResults: [Result<TelegramPaidSendConsent?, TelegramSendApprovalError>] = []
        loading.request(context: context, title: "Synthetic", completion: { loadResults.append($0) })
        guard loadClock.actions.count == 1, loadProvider.capabilityCallbacks.count == 1 else { return XCTFail("No load deadline") }
        loadClock.actions[0]()
        loadProvider.capabilityCallbacks[0](.success(approvalCapabilities(context)))
        XCTAssertEqual(loadResults, [.failure(.timeout)]); XCTAssertNil(loading.pendingPrompt)
        let (confirming, provider, clock) = setup()
        var results: [Result<TelegramPaidSendConsent?, TelegramSendApprovalError>] = []
        guard let prompt = paid(confirming, provider, completion: { results.append($0) }) else { return }
        confirming.confirm(promptID: prompt.id)
        guard clock.actions.count == 2 else { return XCTFail("No confirm deadline") }
        clock.actions[1](); provider.consentCallbacks[0](.success(approvalConsent(prompt)))
        XCTAssertEqual(results, [.failure(.timeout)]); XCTAssertNil(confirming.pendingPrompt)
        XCTAssertEqual(provider.disposedConfirmations, 1)
    }

    // Unknown, malformed or overflowed prices must not become a Pay prompt.
    func testUnknownMalformedAndOverflowFeesDoNotPrompt() {
        for fee: TelegramMessageFee in [.unavailable, .stars(0), .stars(-1), .stars(Int64.max)] {
            let (controller, provider, _) = setup(); provider.immediateFee = fee
            var result: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>?
            controller.request(context: approvalContext(), title: "Synthetic", completion: { result = $0 })
            XCTAssertNotNil(result); XCTAssertNil(controller.pendingPrompt); XCTAssertTrue(provider.confirmations.isEmpty)
            if case .success? = result { XCTFail("Invalid price authorized") }
        }
    }
    // An unrelated sender's cancellation must not cancel the active load/prompt.
    func testContextCancellationMatchesExactLoadingAndDisplayedSubmission() {
        for waiting in [false, true] {
            let (controller, provider, _) = setup(), context = approvalContext()
            var results: [Result<TelegramPaidSendConsent?, TelegramSendApprovalError>] = []
            controller.request(context: context, title: "Current", completion: { results.append($0) })
            guard provider.capabilityCallbacks.count == 1 else { return XCTFail("No active current load") }
            if waiting { provider.capabilityCallbacks[0](.success(approvalCapabilities(context))) }
            let other = approvalContext()
            var busy: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>?
            controller.request(context: other, title: "Other", completion: { busy = $0 })
            XCTAssertEqual(busy, .failure(.busy))
            controller.cancel(context: other)
            XCTAssertTrue(results.isEmpty)
            if waiting { XCTAssertEqual(controller.pendingPrompt?.context, context) }
            controller.cancel(context: context)
            XCTAssertEqual(results, [.failure(.cancelled)])
            XCTAssertNil(controller.pendingPrompt)
            provider.capabilityCallbacks[0](.success(approvalCapabilities(context)))
            XCTAssertEqual(results, [.failure(.cancelled)])
            XCTAssertTrue(provider.confirmations.isEmpty)
        }
    }

}

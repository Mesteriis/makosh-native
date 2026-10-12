import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor private final class ApprovalSignalProvider: TelegramSendApprovalProviding {
    func capabilities(context: TelegramSendContext) -> Signal<Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>, NoError> {
        .single(.success(.init(accountID: context.accountID, chatID: context.chatID, messageFee: .stars(3), secret: nil)))
    }
    func createConsent(context: TelegramSendContext, perMessageStars: Int64, consentID: UUID)
        -> Signal<Result<TelegramPaidSendConsent, TelegramPaidSendConsentError>, NoError> {
        .single(.success(.init(id: consentID, context: context, perMessageStars: perMessageStars,
            totalStars: Int64(context.messageCount) * perMessageStars)))
    }
}
@MainActor final class TelegramSendApprovalSignalTests: XCTestCase {
    private func context() -> TelegramSendContext {
        .init(accountID: 1, chatID: 42, threadID: nil, submissionRevision: UUID(), messageCount: 2)
    }
    // Catches starting a send before the explicit Pay click or losing a synchronous result.
    func testSignalWaitsForExplicitPayAndEmitsExactConsentOnce() async throws {
        let controller = TelegramSendApprovalController(), context = context()
        controller.bind(provider: ApprovalSignalProvider(), accountID: 1)
        var values: [Result<TelegramPaidSendConsent?, TelegramSendApprovalError>] = []
        let lease = telegramSendApprovalSignal(controller: controller, context: context, title: "Synthetic")
            .start(next: { values.append($0) })
        defer { lease.dispose() }
        XCTAssertTrue(values.isEmpty)
        guard let prompt = controller.pendingPrompt else { XCTFail("Send must display explicit approval"); return }
        controller.confirm(promptID: prompt.id)
        XCTAssertEqual(values, [.success(.init(id: prompt.id, context: context, perMessageStars: 3, totalStars: 6))])
        controller.confirm(promptID: prompt.id)
        XCTAssertEqual(values.count, 1)
    }
    // Catches a rejected duplicate lease cancelling somebody else's active prompt,
    // or a cancelled original lease leaving a payment operation active.
    func testDisposalCancelsOnlyOwnedPendingApproval() async throws {
        let controller = TelegramSendApprovalController(), context = context()
        controller.bind(provider: ApprovalSignalProvider(), accountID: 1)
        let original = telegramSendApprovalSignal(controller: controller, context: context, title: "Original").start()
        var duplicateResult: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>?
        let duplicate = telegramSendApprovalSignal(controller: controller, context: context, title: "Duplicate")
            .start(next: { duplicateResult = $0 })
        duplicate.dispose()
        await Task.yield()
        XCTAssertEqual(duplicateResult, .failure(.busy))
        XCTAssertEqual(controller.pendingPrompt?.title, "Original")
        original.dispose()
        for _ in 0..<20 {
            if controller.pendingPrompt == nil { break }
            await Task.yield()
        }
        XCTAssertNil(controller.pendingPrompt)
    }
}

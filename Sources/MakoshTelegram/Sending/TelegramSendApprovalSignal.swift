import Foundation
import SwiftSignalKit

/// One operation owns the approval from construction until its single result
/// or cancellation. Callers create and subscribe on their existing UI lease.
@MainActor func telegramSendApprovalSignal(controller: TelegramSendApprovalController,
    context: TelegramSendContext, title: String)
    -> Signal<Result<TelegramPaidSendConsent?, TelegramSendApprovalError>, NoError> {
    let result = Promise<Result<TelegramPaidSendConsent?, TelegramSendApprovalError>>()
    let pending = Atomic(value: true)
    controller.request(context: context, title: title) { value in
        _ = pending.swap(false)
        result.set(.single(value))
    }
    return result.get() |> take(1) |> afterDisposed {
        if pending.swap(false) {
            Task { @MainActor in controller.cancel(context: context) }
        }
    }
}

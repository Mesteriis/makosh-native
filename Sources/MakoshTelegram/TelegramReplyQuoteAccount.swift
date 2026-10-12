import Postbox
import TelegramCore
import SwiftSignalKit

/// The selected account's current server limit also bounds native reading
/// selection. Actual sending independently checks it in the queue transaction.
nonisolated func telegramReplyQuoteLimitSignal(postbox: Postbox) -> Signal<Int, NoError> {
    let key = PostboxViewKey.preferences(keys: Set([PreferencesKeys.appConfiguration]))
    return postbox.combinedView(keys: [key]) |> mapToSignal { _ in
        postbox.transaction { telegramReplyQuoteLimit(transaction: $0) }
    } |> distinctUntilChanged
}

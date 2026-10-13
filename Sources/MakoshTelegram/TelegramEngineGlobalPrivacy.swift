import Foundation
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit

func telegramPrivacyCapabilities(transaction: Transaction, peerID: PeerId) -> TelegramPrivacyCapabilities? {
    guard peerID.namespace == Namespaces.Peer.CloudUser, let user = transaction.getPeer(peerID) as? TelegramUser,
          user.id == peerID, user.botInfo == nil else { return nil }
    let config = currentAppConfiguration(transaction: transaction)
    var maximum: Int64 = 10000
    if let raw = config.data?["stars_paid_message_amount_max"] {
        if type(of: raw) == Double.self, let number = raw as? Double, number.isFinite,
           number >= 1, number <= Double(Int32.max), number.rounded(.towardZero) == number { maximum = Int64(number) }
        else { maximum = 0 }
    }
    return .init(isPremium: user.flags.contains(.isPremium),
        nonPremiumMessageRestrictionAvailable: config.data?["new_noncontact_peers_require_premium_without_ownpremium"] as? Bool == true,
        paidMessagesAvailable: config.data?["stars_paid_messages_available"] as? Bool == true && maximum > 0, maximumPaidStars: maximum)
}
func telegramGlobalPrivacyRPC(_ setting: TelegramGlobalPrivacySetting) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.GlobalPrivacySettings>)? {
    guard let native = setting.api else { return nil }
    return Api.functions.account.setGlobalPrivacySettings(settings: native)
}
func telegramPerformGlobalPrivacyChange(accountID: Int64, expectedAccountID: Int64, change: TelegramGlobalPrivacyChange,
    load: () -> Signal<(TelegramGlobalPrivacySetting, TelegramPrivacyCapabilities), TelegramPrivacyError>,
    perform: @escaping (TelegramGlobalPrivacySetting) -> Signal<TelegramGlobalPrivacySetting, TelegramPrivacyError>) -> Signal<TelegramGlobalPrivacySetting, TelegramPrivacyError> {
    guard accountID == expectedAccountID else { return .fail(.changed) }
    let operation = load() |> take(1) |> mapToSignal { fresh, capabilities -> Signal<TelegramGlobalPrivacySetting, TelegramPrivacyError> in
        guard fresh == change.expected else { return .fail(.changed) }
        guard let sent = change.replacement(capabilities: capabilities) else { return .fail(.unavailable) }
        return perform(sent) |> take(1) |> mapToSignal { ack -> Signal<TelegramGlobalPrivacySetting, TelegramPrivacyError> in
            guard ack == sent, ack.isValid else { return .fail(.uncertain) }
            return .single(ack)
        }
    }
    return Signal { subscriber in
        let acknowledged = Atomic(value: false)
        return operation.start(next: { value in _ = acknowledged.swap(true); subscriber.putNext(value) }, error: { subscriber.putError($0) }, completed: {
            if acknowledged.with({ $0 }) { subscriber.putCompletion() } else { subscriber.putError(.uncertain) }
        })
    }
}

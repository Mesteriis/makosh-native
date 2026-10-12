import Postbox
import TelegramCore
import SwiftSignalKit

/// No tier exists until this selected account's actual cloud user is present.
nonisolated func telegramUploadCaptionLimit(transaction: Transaction, accountID: Int64) -> Int? {
    guard let user = transaction.getPeer(PeerId(accountID)) as? TelegramUser,
          user.id.namespace == Namespaces.Peer.CloudUser else { return nil }
    return TelegramUploadCaptionLimit.resolve(appConfiguration: currentAppConfiguration(transaction: transaction),
        isPremium: user.flags.contains(.isPremium))
}

public nonisolated func telegramUploadCaptionLimit(postbox: Postbox, accountID: Int64) -> Signal<Int, NoError> {
    let peerKey = PostboxViewKey.basicPeer(PeerId(accountID))
    let configKey = PostboxViewKey.preferences(keys: Set([PreferencesKeys.appConfiguration]))
    return postbox.combinedView(keys: [peerKey, configKey]) |> mapToSignal { view -> Signal<Int, NoError> in
        guard let user = (view.views[peerKey] as? BasicPeerView)?.peer as? TelegramUser,
              user.id.namespace == Namespaces.Peer.CloudUser else { return .never() }
        let config = (view.views[configKey] as? PreferencesView)?.values[PreferencesKeys.appConfiguration]?.get(AppConfiguration.self)
            ?? AppConfiguration.defaultValue
        return .single(TelegramUploadCaptionLimit.resolve(appConfiguration: config, isPremium: user.flags.contains(.isPremium)))
    } |> distinctUntilChanged
}

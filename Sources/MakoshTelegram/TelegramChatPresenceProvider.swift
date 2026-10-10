import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

struct TelegramSearchChatPresenceSource {
    let chat: TelegramChat
    let presencePeerID: PeerId
}

/// One cached Postbox view for the current search, disposed with that request.
/// Associated peers retain the chat's identity while supplying its presence.
func telegramSearchChatPresenceSignal(postbox: Postbox, sources: [TelegramSearchChatPresenceSource],
                                      accountID: Int64, serverTimeOffset: @escaping () -> TimeInterval) -> Signal<[TelegramChat], NoError> {
    guard !sources.isEmpty else { return .single([]) }
    let key = PostboxViewKey.peerPresences(peerIds: Set(sources.map(\.presencePeerID)))
    return postbox.combinedView(keys: [key]) |> map { view in
        let presences = (view.views[key] as? PeerPresencesView)?.presences ?? [:]
        let offset = serverTimeOffset()
        return sources.map { source in
            var chat = source.chat
            chat.presence = telegramChatPresence(presence: presences[source.presencePeerID],
                accountID: accountID, peerID: chat.id, serverTimeOffset: offset)
            return chat
        }
    }
}

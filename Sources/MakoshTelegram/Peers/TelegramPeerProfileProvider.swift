import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Reference peer-info subscription: emits cached observations and requests
/// engine-managed refresh. Disposing ends observation, not an already issued RPC.
func telegramPeerProfileSignal(account: Account, peerID: Int64, accountID: Int64) -> Signal<TelegramContactProfile?, NoError> {
    guard account.peerId.toInt64() == accountID else { return .single(nil) }
    return account.viewTracker.peerView(PeerId(peerID), updateData: true)
        |> map { view -> TelegramContactProfile? in
            guard let peer = view.peers[PeerId(peerID)] else { return nil }
            return telegramContactProfile(peer: peer, accountID: accountID, observedAt: Date(), cachedData: view.cachedData)
        }
        |> deliverOnMainQueue
}

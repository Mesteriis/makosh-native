import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

func telegramPeerStatusSignal(account: Account, peerID: Int64, accountID: Int64) -> Signal<TelegramPeerStatus?, NoError> {
    guard account.peerId.toInt64() == accountID else { return .single(nil) }
    return account.viewTracker.peerView(PeerId(peerID), updateData: false)
        |> map { view -> TelegramPeerStatus? in
            guard let peer = view.peers[PeerId(peerID)] else { return nil }
            return telegramPeerStatus(peer: peer, presence: view.peerPresences[peer.id], cachedData: view.cachedData,
                accountID: accountID, serverTimeOffset: account.network.globalTimeDifference)
        }
        |> deliverOnMainQueue
}

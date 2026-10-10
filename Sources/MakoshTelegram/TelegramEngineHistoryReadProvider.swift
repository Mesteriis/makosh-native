import TelegramCore
import Postbox
import SwiftSignalKit

// Create the legacy engine signal outside MainActor. Its transaction body is
// executed on Postbox's queue; only the completion is delivered on main.
private func historyReadSignal(account: Account, index: MessageIndex) -> Signal<Void, NoError> {
    TelegramEngine(account: account).messages.applyMaxReadIndexInteractively(index: index)
}

@MainActor internal final class TelegramEngineHistoryReadProvider: TelegramHistoryReadProvider {
    let accountID: Int64
    private let account: Account
    init(account: Account) { self.account = account; accountID = account.peerId.toInt64() }

    func apply(_ target: TelegramHistoryReadTarget, completion: @escaping @MainActor (Bool) -> Void) {
        let peer = target.index.id.peerId
        guard target.context.accountID == accountID, peer.id._internalGetInt64Value() > 0,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peer.namespace),
              target.index.id.namespace == Namespaces.Message.Cloud,
              target.index.id.id > 0 else { completion(false); return }
        // Capturing this account in the builder binds an accepted operation to
        // its original session. Disposing UI state cannot undo a local commit.
        let _ = (historyReadSignal(account: account, index: target.index) |> deliverOnMainQueue)
            .startStandalone(completed: { MainActor.assumeIsolated { completion(true) } })
    }
}

import Foundation
import Combine
import TelegramCore
import Postbox
import SwiftSignalKit

@MainActor public final class TelegramPeerStatusController: ObservableObject {
    @Published public private(set) var status: TelegramPeerStatus?
    private var provider: ((Int64) -> Signal<TelegramPeerStatus?, NoError>)?
    private var accountID: Int64?
    private var peerID: Int64?
    private var visible = false
    private var contextID = UUID()
    private let subscription = MetaDisposable()
    private var deadline: Task<Void, Never>?
    var requestID: UUID?
    public init() {}
    isolated deinit { deadline?.cancel(); subscription.dispose() }

    func bind(account: Account?) {
        bind(accountID: account?.peerId.toInt64(), provider: account.map { account in
            { peerID in telegramPeerStatusSignal(account: account, peerID: peerID, accountID: account.peerId.toInt64()) }
        })
    }

    func bind(accountID: Int64?, provider: ((Int64) -> Signal<TelegramPeerStatus?, NoError>)?) {
        cancel(); contextID = UUID()
        self.accountID = accountID; self.provider = provider
        load()
    }

    func selectPeer(_ peerID: Int64?) {
        guard peerID != self.peerID else { return }
        self.peerID = peerID; load()
    }

    public func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible; load()
    }

    private func load() {
        cancel()
        guard visible, let peerID, let accountID, let provider else { return }
        let request = UUID(), context = contextID
        requestID = request
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.requestID == request else { return }
            self.cancel()
        }
        subscription.set(provider(peerID).start(next: { [weak self] value in
            MainActor.assumeIsolated {
                self?.receive(value, requestID: request, contextID: context, accountID: accountID, peerID: peerID)
            }
        }))
    }

    private func receive(_ value: TelegramPeerStatus?, requestID: UUID, contextID: UUID, accountID: Int64, peerID: Int64) {
        guard visible, self.requestID == requestID, self.contextID == contextID,
              self.accountID == accountID, self.peerID == peerID,
              value == nil || (value?.accountID == accountID && value?.peerID == peerID) else { return }
        deadline?.cancel(); deadline = nil
        status = value
    }

    private func cancel() {
        requestID = nil; status = nil
        deadline?.cancel(); deadline = nil; subscription.set(nil)
    }

    #if DEBUG
    func useSyntheticPreview() {
        bind(accountID: -1) { peerID in .single(telegramSyntheticPeerStatus(peerID: peerID)) }
    }
    #endif
}

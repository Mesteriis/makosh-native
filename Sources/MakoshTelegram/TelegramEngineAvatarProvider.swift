import Foundation
import CryptoKit
import TelegramCore
import Postbox
import SwiftSignalKit

struct TelegramNativeAvatarSource: Equatable {
    let id: String
    let resource: MediaResource
    let reference: PeerReference?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.reference == rhs.reference
    }
}

func telegramNativeAvatarSource(peer: Peer, size: TelegramAvatarSize) -> TelegramNativeAvatarSource? {
    guard (peer is TelegramUser && peer.id.namespace == Namespaces.Peer.CloudUser)
        || (peer is TelegramGroup && peer.id.namespace == Namespaces.Peer.CloudGroup)
        || (peer is TelegramChannel && peer.id.namespace == Namespaces.Peer.CloudChannel),
        let photo = size == .small ? peer.smallProfileImage : peer.largeProfileImage,
        !(photo.resource is EmptyMediaResource) else { return nil }
    let id = SHA256.hash(data: Data(photo.resource.id.stringRepresentation.utf8))
        .map { String(format: "%02x", $0) }.joined()
    return TelegramNativeAvatarSource(id: id, resource: photo.resource, reference: PeerReference(peer))
}

// All native peer/resource values remain on the engine signal side of main delivery.
private func telegramAvatarEvents(account: Account, key: TelegramAvatarKey) -> Signal<TelegramAvatarEvent, NoError> {
    account.viewTracker.peerView(PeerId(key.peerID), updateData: false)
        |> map { view in view.peers[PeerId(key.peerID)].flatMap { telegramNativeAvatarSource(peer: $0, size: key.size) } }
        |> distinctUntilChanged
        |> mapToSignal { source -> Signal<TelegramAvatarEvent, NoError> in
            guard let source else { return .single(.resource(nil)) }
            return Signal { subscriber in
                let keep = MetaDisposable(), data = MetaDisposable(), fetch = MetaDisposable()
                let ended = Atomic(value: false)
                let stop: () -> Bool = { !ended.swap(true) }
                subscriber.putNext(.resource(source.id))
                keep.set(account.postbox.mediaBox.keepResource(id: source.resource.id).start())
                data.set(account.postbox.mediaBox.resourceData(source.resource, pathExtension: nil,
                    option: .complete(waitUntilFetchStatus: false)).start(next: { value in
                    guard value.complete, value.offset == 0, value.size > 0, stop() else { return }
                    data.dispose(); fetch.dispose()
                    subscriber.putNext(.data(resourceID: source.id, url: URL(fileURLWithPath: value.path), size: value.size))
                }))
                if !ended.with({ $0 }), let reference = source.reference {
                    fetch.set(fetchedMediaResource(mediaBox: account.postbox.mediaBox,
                        userLocation: .peer(PeerId(key.peerID)), userContentType: .avatar,
                        reference: .avatar(peer: reference, resource: source.resource),
                        continueInBackground: false).start(error: { _ in
                            guard stop() else { return }
                            data.dispose(); fetch.dispose(); keep.dispose()
                            subscriber.putNext(.failed(resourceID: source.id))
                        }))
                }
                Queue.concurrentDefaultQueue().after(30) {
                    guard stop() else { return }
                    data.dispose(); fetch.dispose(); keep.dispose()
                    subscriber.putNext(.failed(resourceID: source.id))
                }
                return ActionDisposable { _ = ended.swap(true); data.dispose(); fetch.dispose(); keep.dispose() }
            }
        }
}

@MainActor final class TelegramEngineAvatarProvider: TelegramAvatarProvider {
    private let account: Account
    init(account: Account) { self.account = account }
    func start(key: TelegramAvatarKey, receive: @escaping @MainActor (TelegramAvatarEvent) -> Void) -> any TelegramAvatarLease {
        let lease = EngineAvatarLease()
        lease.subscription.set((telegramAvatarEvents(account: account, key: key) |> deliverOnMainQueue)
            .start(next: { event in MainActor.assumeIsolated { receive(event) } }))
        return lease
    }
}

@MainActor private final class EngineAvatarLease: TelegramAvatarLease {
    let subscription = MetaDisposable()
    func cancel() { subscription.dispose() }
    isolated deinit { subscription.dispose() }
}

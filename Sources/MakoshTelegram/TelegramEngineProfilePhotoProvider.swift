import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

// Native registry never appears in a UI callback; only immutable DTOs/events do.
private final class ProfilePhotoBackend {
    let account: Account
    let peerID: PeerId
    let sources = Atomic<[String: TelegramNativeProfilePhoto]>(value: [:])
    init(account: Account, peerID: Int64) { self.account = account; self.peerID = PeerId(peerID) }
    func list() -> Signal<[TelegramProfilePhoto], NoError> {
        account.postbox.peerView(id: peerID) |> take(1) |> mapToSignal { [self] view in
            guard let peer = view.peers[peerID],
                (peer is TelegramUser && peer.id.namespace == Namespaces.Peer.CloudUser)
                || (peer is TelegramGroup && peer.id.namespace == Namespaces.Peer.CloudGroup)
                || (peer is TelegramChannel && peer.id.namespace == Namespaces.Peer.CloudChannel) else { return .single([]) }
            let request: Signal<[TelegramPeerPhoto], NoError>
            if PeerReference(peer) != nil,
               peer.id.namespace == Namespaces.Peer.CloudUser || peer.id.namespace == Namespaces.Peer.CloudGroup || peer.id.namespace == Namespaces.Peer.CloudChannel {
                request = TelegramEngine(account: account).peers.requestPeerPhotos(peerId: peerID)
            } else { request = .single([]) }
            return request |> map { [self] photos in
                let mapped = telegramProfilePhotos(peer: peer, cachedData: view.cachedData, photos: photos)
                _ = sources.swap(Dictionary(uniqueKeysWithValues: mapped.map { ($0.value.id, $0) }))
                return mapped.map(\.value)
            }
        }
    }
    func image(_ id: String) -> Signal<TelegramProfilePhotoImageEvent, NoError> {
        Signal { [self] subscriber in
            guard let source = sources.with({ $0[id] }) else { subscriber.putNext(.failed); return EmptyDisposable }
            let keep = MetaDisposable(), data = MetaDisposable(), fetch = MetaDisposable()
            let ended = Atomic(value: false)
            keep.set(account.postbox.mediaBox.keepResource(id: source.resource.id).start())
            data.set(account.postbox.mediaBox.resourceData(source.resource, pathExtension: nil,
                option: .complete(waitUntilFetchStatus: false)).start(next: { value in
                guard value.complete, value.offset == 0, value.size > 0, !ended.swap(true) else { return }
                data.dispose(); fetch.dispose()
                subscriber.putNext(.data(url: URL(fileURLWithPath: value.path), size: value.size))
            }))
            if !ended.with({ $0 }), let reference = source.reference {
                fetch.set(fetchedMediaResource(mediaBox: account.postbox.mediaBox,
                    userLocation: .peer(peerID), userContentType: .avatar, reference: reference,
                    continueInBackground: false).start(error: { _ in
                        guard !ended.swap(true) else { return }
                        data.dispose(); fetch.dispose(); keep.dispose(); subscriber.putNext(.failed)
                    }))
            }
            Queue.concurrentDefaultQueue().after(30) {
                guard !ended.swap(true) else { return }
                data.dispose(); fetch.dispose(); keep.dispose(); subscriber.putNext(.failed)
            }
            return ActionDisposable { _ = ended.swap(true); data.dispose(); fetch.dispose(); keep.dispose() }
        }
    }
}

@MainActor final class TelegramEngineProfilePhotoProvider: TelegramProfilePhotoProvider {
    private let account: Account
    init(account: Account) { self.account = account }
    func load(peerID: Int64, receive: @escaping @MainActor ([TelegramProfilePhoto]) -> Void) -> any TelegramProfilePhotoSession {
        let session = EngineProfilePhotoSession(backend: ProfilePhotoBackend(account: account, peerID: peerID))
        session.load.set((session.backend.list() |> deliverOnMainQueue).start(next: { values in
            MainActor.assumeIsolated { receive(values) }
        }))
        return session
    }
}

@MainActor private final class EngineProfilePhotoSession: TelegramProfilePhotoSession {
    let backend: ProfilePhotoBackend
    let load = MetaDisposable()
    private var currentLease: EngineProfilePhotoLease?
    private var cancelled = false
    init(backend: ProfilePhotoBackend) { self.backend = backend }
    func image(photoID: String, receive: @escaping @MainActor (TelegramProfilePhotoImageEvent) -> Void) -> any TelegramAvatarLease {
        let lease = EngineProfilePhotoLease()
        guard !cancelled else { lease.cancel(); return lease }
        currentLease?.cancel(); currentLease = lease
        lease.subscription.set((backend.image(photoID) |> deliverOnMainQueue).start(next: { event in
            MainActor.assumeIsolated { receive(event) }
        }))
        return lease
    }
    func cancel() { cancelled = true; load.dispose(); currentLease?.cancel(); currentLease = nil }
    isolated deinit { cancel() }
}
@MainActor private final class EngineProfilePhotoLease: TelegramAvatarLease {
    let subscription = MetaDisposable()
    func cancel() { subscription.dispose() }
    isolated deinit { subscription.dispose() }
}

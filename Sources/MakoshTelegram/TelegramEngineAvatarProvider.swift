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
    func startVideo(key:TelegramAvatarKey,receive:@escaping @MainActor (TelegramAvatarVideoEvent)->Void) -> (any TelegramAvatarLease)? {
        let lease = EngineAvatarLease()
        lease.subscription.set((telegramVideoAvatarEvents(account:account,key:key) |> deliverOnMainQueue).start(next:{ event in MainActor.assumeIsolated { receive(event) } }))
        return lease
    }
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

struct TelegramNativeVideoAvatarSource: Equatable {
    let id: String
    let resource: TelegramMediaResource
    let reference: MediaResourceReference?
    let peerReference: PeerReference?
    let start: Double
    static func == (lhs:Self,rhs:Self) -> Bool { lhs.id == rhs.id && lhs.start == rhs.start && lhs.resource.isEqual(to:rhs.resource) && lhs.peerReference == rhs.peerReference }
}
nonisolated func telegramNativeVideoAvatarSource(peer:Peer,cachedData:CachedPeerData?,photos:[TelegramPeerPhoto]) -> TelegramNativeVideoAvatarSource? {
    guard let user = peer as? TelegramUser,!user.isDeleted,peer.id.namespace == Namespaces.Peer.CloudUser,
          let current = peer.largeProfileImage?.resource as? CloudPeerPhotoSizeMediaResource,
          let photoID = current.photoId else { return nil }
    var images: [TelegramMediaImage] = []
    if let cached = cachedData as? CachedUserData {
        if case let .known(image?) = cached.personalPhoto { images.append(image) }
        if case let .known(image?) = cached.photo { images.append(image) }
    }
    images.append(contentsOf:photos.prefix(128).map(\.image))
    guard let image = images.first(where:{ $0.imageId.id == photoID && $0.imageId.namespace == Namespaces.Media.CloudImage }),
          let video = image.videoRepresentations.filter({
              $0.dimensions.width > 0 && $0.dimensions.height > 0 && $0.dimensions.width <= 1024 && $0.dimensions.height <= 1024 &&
              ($0.resource as? CloudPhotoSizeMediaResource)?.photoId == photoID && ($0.resource.size.map { (1...16_777_216).contains($0) } ?? false)
          }).min(by:{ Int64($0.dimensions.width)*Int64($0.dimensions.height) < Int64($1.dimensions.width)*Int64($1.dimensions.height) }) else { return nil }
    let start = video.startTimestamp ?? 0
    guard start.isFinite,(0...30).contains(start) else { return nil }
    let encoder = PostboxEncoder(); encoder.encodeObject(video.resource,forKey:"resource"); encoder.encodeDouble(start,forKey:"start")
    let id = SHA256.hash(data:encoder.makeData()).map { String(format:"%02x",$0) }.joined()
    let peerReference = PeerReference(peer)
    return .init(id:id,resource:video.resource,reference:peerReference.map { AnyMediaReference.avatarList(peer:$0,media:image).resourceReference(video.resource) },peerReference:peerReference,start:start)
}
private struct VideoAvatarLookup: Equatable {
    let peer: Peer
    let cachedData: CachedPeerData?
    let source: TelegramNativeVideoAvatarSource?
    static func == (lhs:Self,rhs:Self) -> Bool { lhs.peer.isEqual(rhs.peer) && lhs.source == rhs.source }
}
private nonisolated func telegramVideoAvatarEvents(account:Account,key:TelegramAvatarKey) -> Signal<TelegramAvatarVideoEvent,NoError> {
    let peerID = PeerId(key.peerID)
    return account.viewTracker.peerView(peerID,updateData:false) |> map { view -> VideoAvatarLookup? in
        guard let peer = view.peers[peerID] as? TelegramUser,!peer.isDeleted,peerID.namespace == Namespaces.Peer.CloudUser else { return nil }
        return .init(peer:peer,cachedData:view.cachedData,source:telegramNativeVideoAvatarSource(peer:peer,cachedData:view.cachedData,photos:[]))
    } |> distinctUntilChanged |> mapToSignal { lookup -> Signal<TelegramAvatarVideoEvent,NoError> in
        guard let lookup else { return .single(.resource(nil,start:0)) }
        let source: Signal<TelegramNativeVideoAvatarSource?,NoError>
        if let cached = lookup.source { source = .single(cached) }
        else if PeerReference(lookup.peer) != nil,lookup.peer.largeProfileImage != nil {
            source = TelegramEngine(account:account).peers.requestPeerPhotos(peerId:peerID)
                |> timeout(30,queue:Queue.concurrentDefaultQueue(),alternate:.single([]))
                |> map { telegramNativeVideoAvatarSource(peer:lookup.peer,cachedData:lookup.cachedData,photos:$0) }
        } else { source = .single(nil) }
        return .single(.resource(nil,start:0)) |> then(source |> mapToSignal { source -> Signal<TelegramAvatarVideoEvent,NoError> in
            guard let source else { return .single(.resource(nil,start:0)) }
            return Signal { subscriber in
                let keep = MetaDisposable(),data = MetaDisposable(),fetch = MetaDisposable(),ended = Atomic(value:false)
                subscriber.putNext(.resource(source.id,start:source.start))
                keep.set(account.postbox.mediaBox.keepResource(id:source.resource.id).start())
                data.set(account.postbox.mediaBox.resourceData(source.resource,pathExtension:nil,option:.complete(waitUntilFetchStatus:false)).start(next:{ value in
                    guard value.complete,!ended.swap(true) else { return }
                    data.dispose(); fetch.dispose()
                    guard value.offset == 0,value.size == source.resource.size,value.size > 0,value.size <= 16_777_216 else {
                        keep.dispose(); subscriber.putNext(.failed(resourceID:source.id)); return
                    }
                    subscriber.putNext(.data(resourceID:source.id,url:URL(fileURLWithPath:value.path),size:value.size))
                }))
                if !ended.with({ $0 }),let reference = source.reference {
                    fetch.set(fetchedMediaResource(mediaBox:account.postbox.mediaBox,userLocation:.peer(peerID),userContentType:.avatar,reference:reference,continueInBackground:false).start(error:{ _ in
                        guard !ended.swap(true) else { return }; data.dispose(); fetch.dispose(); keep.dispose(); subscriber.putNext(.failed(resourceID:source.id))
                    }))
                }
                Queue.concurrentDefaultQueue().after(30) {
                    guard !ended.swap(true) else { return }; data.dispose(); fetch.dispose(); keep.dispose(); subscriber.putNext(.failed(resourceID:source.id))
                }
                return ActionDisposable { _ = ended.swap(true); data.dispose(); fetch.dispose(); keep.dispose() }
            }
        })
    }
}

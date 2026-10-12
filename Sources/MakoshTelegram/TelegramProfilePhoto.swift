import Foundation
import CryptoKit
import TelegramCore
import Postbox

public struct TelegramProfilePhoto: Equatable, Sendable {
    public let id: String
    public let date: Int32
    public let totalCount: Int
    public let hasVideo: Bool
}

enum TelegramProfilePhotoImageEvent: Sendable {
    case data(url: URL, size: Int64)
    case failed
}

@MainActor protocol TelegramProfilePhotoProvider: AnyObject {
    func load(peerID: Int64, receive: @escaping @MainActor ([TelegramProfilePhoto]) -> Void) -> any TelegramProfilePhotoSession
}
@MainActor protocol TelegramProfilePhotoSession: AnyObject {
    func image(photoID: String, receive: @escaping @MainActor (TelegramProfilePhotoImageEvent) -> Void) -> any TelegramAvatarLease
    func thumbnail(photoID: String, receive: @escaping @MainActor (TelegramProfilePhotoImageEvent) -> Void) -> any TelegramAvatarLease
    func cancel()
}

struct TelegramNativeProfilePhoto {
    let value: TelegramProfilePhoto
    let resource: MediaResource
    let reference: MediaResourceReference?
    let thumbnailResource: MediaResource
    let thumbnailReference: MediaResourceReference?
}

func telegramProfilePhotos(peer: Peer, cachedData: CachedPeerData?, photos: [TelegramPeerPhoto]) -> [TelegramNativeProfilePhoto] {
    guard (peer is TelegramUser && peer.id.namespace == Namespaces.Peer.CloudUser)
        || (peer is TelegramGroup && peer.id.namespace == Namespaces.Peer.CloudGroup)
        || (peer is TelegramChannel && peer.id.namespace == Namespaces.Peer.CloudChannel) else { return [] }
    var input = photos
    var cached: TelegramMediaImage?
    if let data = cachedData as? CachedUserData {
        if case let .known(image?) = data.personalPhoto { cached = image }
        else if case let .known(image?) = data.photo { cached = image }
    } else if let data = cachedData as? CachedGroupData { cached = data.photo }
    else if let data = cachedData as? CachedChannelData { cached = data.photo }
    if let cached, !input.contains(where: { $0.image.imageId == cached.imageId }) {
        input.insert(TelegramPeerPhoto(image: cached, reference: cached.reference, date: 0, index: 0,
            totalCount: input.first?.totalCount ?? 0, messageId: nil), at: 0)
    }
    var usesCurrentAvatar = false
    let current = peer.largeProfileImage
    if input.isEmpty, let current, !(current.resource is EmptyMediaResource) {
        usesCurrentAvatar = true
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 0),
            representations: peer.profileImageRepresentations, immediateThumbnailData: nil,
            reference: nil, partialReference: nil, flags: [])
        input = [TelegramPeerPhoto(image: image, reference: nil, date: 0, index: 0, totalCount: 0, messageId: nil)]
    }
    var seen = Set<MediaId>()
    return input.compactMap { photo in
        guard seen.insert(photo.image.imageId).inserted,
              let representation = photo.image.representationForDisplayAtSize(PixelDimensions(width: 1280, height: 1280)),
              !(representation.resource is EmptyMediaResource) else { return nil }
        let identity = "\(photo.image.imageId.namespace):\(photo.image.imageId.id):\(representation.resource.id.stringRepresentation)"
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let reference: MediaResourceReference?
        if let peerReference = PeerReference(peer) {
            // avatarList carries the full historical image for native reference revalidation.
            reference = usesCurrentAvatar ? .avatar(peer: peerReference, resource: representation.resource)
                : AnyMediaReference.avatarList(peer: peerReference, media: photo.image).resourceReference(representation.resource)
        } else { reference = nil }
        let thumb = smallestImageRepresentation(photo.image.representations.filter { !($0.resource is EmptyMediaResource) })?.resource ?? representation.resource
        let thumbReference: MediaResourceReference? = PeerReference(peer).map {
            usesCurrentAvatar ? .avatar(peer: $0, resource: thumb)
                : AnyMediaReference.avatarList(peer: $0, media: photo.image).resourceReference(thumb)
        }
        return TelegramNativeProfilePhoto(value: TelegramProfilePhoto(id: id, date: photo.date,
            totalCount: max(0, photo.totalCount), hasVideo: !photo.image.videoRepresentations.isEmpty || photo.image.representations.contains(where: { $0.hasVideo })),
            resource: representation.resource, reference: reference, thumbnailResource: thumb, thumbnailReference: thumbReference)
    }
}

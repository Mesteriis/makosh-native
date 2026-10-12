import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramProfilePhotoMappingTests: XCTestCase {
    private func representation(_ id: Int64) -> TelegramMediaImageRepresentation {
        TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 640, height: 640),
            resource: CloudPeerPhotoSizeMediaResource(datacenterId: 1, photoId: id, sizeSpec: .fullSize,
                volumeId: nil, localId: nil), progressiveSizes: [], immediateThumbnailData: nil)
    }
    private func group(photos: [TelegramMediaImageRepresentation] = [], namespace: PeerId.Namespace = Namespaces.Peer.CloudGroup) -> TelegramGroup {
        TelegramGroup(id: PeerId(namespace: namespace, id: ._internalFromInt64Value(7)), title: "Synthetic",
            photo: photos, participantCount: 2, role: .member, membership: .Member, flags: [],
            defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 1)
    }
    private func photo(_ id: Int64, count: Int = 12) -> TelegramPeerPhoto {
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: id),
            representations: [representation(id)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        return TelegramPeerPhoto(image: image, reference: nil, date: 123, index: 0, totalCount: count, messageId: nil)
    }
    func testHistoryDeduplicatesImagesPreservingNativeMetadataAndReference() throws {
        let first = photo(1), second = photo(2)
        let mapped = telegramProfilePhotos(peer: group(), cachedData: nil, photos: [first, first, second])
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[0].value.date, 123); XCTAssertEqual(mapped[0].value.totalCount, 12)
        XCTAssertFalse(mapped[0].value.hasVideo)
        XCTAssertEqual(mapped[0].value.id.count, 64)
        XCTAssertNotEqual(mapped[0].value.id, mapped[1].value.id)
        guard case .media(media: .avatarList, resource: _) = try XCTUnwrap(mapped[0].reference) else {
            return XCTFail("Historical image must retain avatar-list revalidation context")
        }
        XCTAssertEqual(mapped.map(\.value), telegramProfilePhotos(peer: group(), cachedData: nil, photos: [first, second]).map(\.value))
    }
    func testCachedPersonalPhotoPrecedesPublicAndDeduplicatesNativeImageID() throws {
        let personal = photo(8), published = photo(9), historical = photo(10)
        let cached = CachedUserData().withUpdatedPhoto(.known(published.image))
            .withUpdatedPersonalPhoto(.known(personal.image))
        let user = TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42)),
            accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
            photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil,
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        let mapped = telegramProfilePhotos(peer: user, cachedData: cached, photos: [historical])
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[0].resource.id, personal.image.representations[0].resource.id)
        XCTAssertEqual(mapped[0].value.date, 0); XCTAssertEqual(mapped[0].value.totalCount, 12)
        let dedup = telegramProfilePhotos(peer: user, cachedData: cached, photos: [personal, historical])
        XCTAssertEqual(dedup.count, 2); XCTAssertEqual(dedup[0].value.date, 123)
        let publicOnly = telegramProfilePhotos(peer: user,
            cachedData: CachedUserData().withUpdatedPhoto(.known(published.image)), photos: [])
        XCTAssertEqual(publicOnly.first?.resource.id, published.image.representations[0].resource.id)
    }
    func testMissingUserAccessHashRemainsCacheOnly() throws {
        let user = TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42)),
            accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
            photo: [representation(9)], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil,
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        let mapped = try XCTUnwrap(telegramProfilePhotos(peer: user, cachedData: nil, photos: []).first)
        XCTAssertNil(mapped.reference)
        XCTAssertEqual(mapped.value.date, 0)
    }
    func testEmptyInvalidAndCurrentFallback() {
        XCTAssertTrue(telegramProfilePhotos(peer: group(), cachedData: nil, photos: []).isEmpty)
        XCTAssertTrue(telegramProfilePhotos(peer: group(namespace: Namespaces.Peer.SecretChat), cachedData: nil, photos: [photo(1)]).isEmpty)
        let fallback = telegramProfilePhotos(peer: group(photos: [representation(9)]), cachedData: nil, photos: [])
        XCTAssertEqual(fallback.count, 1); XCTAssertEqual(fallback.first?.value.date, 0)
        XCTAssertEqual(fallback.first?.value.totalCount, 0)
        XCTAssertEqual(telegramProfilePhotos(peer: group(), cachedData: nil, photos: [photo(1, count: -3)]).first?.value.totalCount, 0)
        let empty = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 4),
            representations: [], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        XCTAssertTrue(telegramProfilePhotos(peer: group(), cachedData: nil, photos: [TelegramPeerPhoto(image: empty,
            reference: nil, date: 0, index: 0, totalCount: 0, messageId: nil)]).isEmpty)
    }
}

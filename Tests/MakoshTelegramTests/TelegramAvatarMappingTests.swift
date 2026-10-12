import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramAvatarMappingTests: XCTestCase {
    private func photo(_ id: Int64, pixels: Int32) -> TelegramMediaImageRepresentation {
        TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: pixels, height: pixels),
            resource: CloudPeerPhotoSizeMediaResource(datacenterId: 1, photoId: id, sizeSpec: .small,
                volumeId: nil, localId: nil), progressiveSizes: [], immediateThumbnailData: nil)
    }
    private func user(photos: [TelegramMediaImageRepresentation], namespace: PeerId.Namespace = Namespaces.Peer.CloudUser) -> TelegramUser {
        TelegramUser(id: PeerId(namespace: namespace, id: ._internalFromInt64Value(42)), accessHash: nil,
            firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: photos,
            botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            subscriberCount: nil, verificationIconFileId: nil)
    }
    func testSmallLargeAndOpaqueResourceIdentity() throws {
        let small = photo(10, pixels: 64), large = photo(20, pixels: 640)
        let peer = user(photos: [large, small])
        let first = try XCTUnwrap(telegramNativeAvatarSource(peer: peer, size: .small))
        let second = try XCTUnwrap(telegramNativeAvatarSource(peer: peer, size: .large))
        XCTAssertEqual(first.resource.id, small.resource.id)
        XCTAssertEqual(second.resource.id, large.resource.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.id.count, 64)
        XCTAssertNil(first.reference, "Missing access hash must remain cache-only")
        XCTAssertEqual(first, telegramNativeAvatarSource(peer: peer, size: .small))
        XCTAssertNotEqual(first, telegramNativeAvatarSource(peer: user(photos: [photo(30, pixels: 64)]), size: .small))
    }
    func testNoPhotoAndWrongNamespaceHaveNoSource() {
        XCTAssertNil(telegramNativeAvatarSource(peer: user(photos: []), size: .small))
        XCTAssertNil(telegramNativeAvatarSource(peer: user(photos: [photo(1, pixels: 64)],
            namespace: Namespaces.Peer.SecretChat), size: .large))
    }
    func testEmptyResourceIsNotFetchableAvatar() {
        let placeholder = TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 64, height: 64),
            resource: EmptyMediaResource(), progressiveSizes: [], immediateThumbnailData: nil)
        XCTAssertNil(telegramNativeAvatarSource(peer: user(photos: [placeholder]), size: .small))
        XCTAssertNil(telegramNativeAvatarSource(peer: user(photos: [placeholder]), size: .large))
    }
    func testBasicGroupHasNativePeerReference() throws {
        let group = TelegramGroup(id: PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(7)),
            title: "Synthetic", photo: [photo(1, pixels: 64)], participantCount: 2, role: .member,
            membership: .Member, flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 1)
        let source = try XCTUnwrap(telegramNativeAvatarSource(peer: group, size: .small))
        XCTAssertEqual(source.reference, PeerReference(group))
        XCTAssertNotNil(source.reference)
    }
}

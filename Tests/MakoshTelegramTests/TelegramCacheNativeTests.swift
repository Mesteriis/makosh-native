import XCTest
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func cacheFile(_ id: Int64, resource: TelegramMediaResource) -> TelegramMediaFile {
    TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil,
        resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil,
        mimeType: "application/octet-stream", size: 8, attributes: [.FileName(fileName: "Synthetic.bin")], alternativeRepresentations: [])
}
private nonisolated func cacheCatalogue(_ box: Postbox, invalid: Bool = false, foreignMapping: Bool = false, secretReference: Bool = false, distinctSecretReference: Bool = false) -> Signal<TelegramCacheSnapshot?, NoError> {
    box.transaction { tx in
        let cloud = cacheFile(301, resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 301, accessHash: 53,
            size: 8, fileReference: nil, fileName: nil))
        let local = cacheFile(302, resource: LocalFileMediaResource(fileId: 302, size: 16, isSecretRelated: false))
        tx.storeMediaIfNotPresent(media: cloud); tx.storeMediaIfNotPresent(media: local)
        var media: [PeerId:[PeerCacheUsageCategory:[MediaId:Int64]]] = [PeerId(37): [.file: [cloud.fileId: invalid ? -1 : 8, local.fileId: 16]],PeerId(38): [.file: [cloud.fileId:8]]]
        var resources = [cloud.fileId: [foreignMapping ? local.resource.id : cloud.resource.id], local.fileId: [local.resource.id]]
        if secretReference { media[PeerId(namespace:Namespaces.Peer.SecretChat,id:PeerId.Id._internalFromInt64Value(1))] = [.file:[cloud.fileId:8]] }
        if distinctSecretReference {
            let secret = cacheFile(303,resource:cloud.resource); tx.storeMediaIfNotPresent(media:secret)
            media[PeerId(namespace:Namespaces.Peer.SecretChat,id:PeerId.Id._internalFromInt64Value(2))] = [.file:[secret.fileId:8]]
            resources[secret.fileId] = [cloud.resource.id]
        }
        let stats = CacheUsageStats(media: media,
            mediaResourceIds: resources,
            peers: [:], otherSize: 999, otherPaths: ["/synthetic/retained"], cacheSize: 999,
            tempPaths: ["/synthetic/sending"], tempSize: 999, immutableSize: 999)
        return telegramCacheSnapshot(transaction: tx, stats: stats, accountID: 11)
    }
}
@MainActor final class TelegramCacheNativeTests: XCTestCase {
    func testCatalogueCountsSharedCloudResourceOnceAndExcludesLocalOtherImmutableAndTempPaths() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(cacheCatalogue(box), test: self)
        let snapshot = try XCTUnwrap(value)
        XCTAssertEqual(snapshot.totalBytes, 8); XCTAssertEqual(snapshot.bytes(for: .files), 8)
        XCTAssertEqual(snapshot.items.first?.peerIDs,[37,38])
        XCTAssertEqual(snapshot.items.count, 1); XCTAssertEqual(snapshot.items.first?.resources, ["telegram-cloud-document-2-301"])
    }
    func testCloudResourceAlsoReferencedBySecretChatIsExcluded() async throws {
        let box = try await telegramDataPostbox(test:self)
        let value = try await telegramDataValue(cacheCatalogue(box,secretReference:true),test:self)
        XCTAssertEqual(value?.totalBytes,0)
    }
    func testSeparateMediaIdentitySharingSecretResourceIsExcluded() async throws {
        let box = try await telegramDataPostbox(test:self)
        let value = try await telegramDataValue(cacheCatalogue(box,distinctSecretReference:true),test:self)
        XCTAssertEqual(value?.totalBytes,0)
    }
    func testInvalidOrForeignCacheMappingCannotAuthorizeResources() async throws {
        let box = try await telegramDataPostbox(test: self)
        let invalid = try await telegramDataValue(cacheCatalogue(box, invalid: true), test: self)
        XCTAssertNil(invalid)
        let foreign = try await telegramDataValue(cacheCatalogue(box, foreignMapping: true), test: self)
        XCTAssertEqual(foreign?.totalBytes, 0)
    }
    func testActualCloudCacheRemovalPreservesLocalSendingOriginalAndUnrelatedRetainedFile() async throws {
        let box = try await telegramDataPostbox(test: self)
        let cloud = cacheFile(101, resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 101,
            accessHash: 53, size: 8, fileReference: Data([1]), fileName: "Synthetic.bin"))
        let local = cacheFile(102, resource: LocalFileMediaResource(fileId: 102, size: 8, isSecretRelated: false))
        box.mediaBox.storeResourceData(cloud.resource.id, data: Data(repeating: 1, count: 8), synchronous: true)
        box.mediaBox.storeResourceData(local.resource.id, data: Data(repeating: 2, count: 8), synchronous: true)
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-retained-\(UUID())")
        try Data("Retained archive".utf8).write(to: retained)
        defer { try? FileManager.default.removeItem(at: retained) }
        XCTAssertEqual(box.mediaBox.resourceUsage(id: cloud.resource.id), 8)
        let removed = try await telegramDataValue(telegramRemoveCloudCache(mediaBox: box.mediaBox, media: [cloud, local],
            restrictingTo: [cloud.resource.id,local.resource.id]), test: self)
        XCTAssertEqual(Set(removed), [cloud.resource.id])
        XCTAssertEqual(box.mediaBox.resourceUsage(id: cloud.resource.id), 0)
        XCTAssertEqual(box.mediaBox.resourceUsage(id: local.resource.id), 8)
        XCTAssertEqual(try Data(contentsOf: retained), Data("Retained archive".utf8))
    }
    func testActiveLeaseIsNotForcedAndOnlyConfirmedResourceIDsMayBeRemoved() async throws {
        let box = try await telegramDataPostbox(test: self)
        let cloud = cacheFile(201, resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 201,
            accessHash: 53, size: 8, fileReference: Data([1]), fileName: "Synthetic.bin"))
        let other = cacheFile(202, resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 202,
            accessHash: 53, size: 8, fileReference: Data([1]), fileName: "Synthetic.bin"))
        for file in [cloud, other] { box.mediaBox.storeResourceData(file.resource.id, data: Data(repeating: 1, count: 8), synchronous: true) }
        let lease = box.mediaBox.keepResource(id: cloud.resource.id).start()
        defer { lease.dispose() }
        let local = expectation(description: "Protected cache remains local")
        var last: MediaResourceStatus?
        let status = (box.mediaBox.resourceStatus(cloud.resource) |> deliverOnMainQueue).start(next: { value in
            if last == nil, case .Local = value { local.fulfill() }
            last = value
        })
        defer { status.dispose() }
        await fulfillment(of: [local], timeout: 5)
        let removed = try await telegramDataValue(telegramRemoveCloudCache(mediaBox: box.mediaBox, media: [cloud,other],
            restrictingTo: [cloud.resource.id]), test: self)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(box.mediaBox.resourceUsage(id: cloud.resource.id), 8)
        XCTAssertEqual(box.mediaBox.resourceUsage(id: other.resource.id), 8)
        if case .Local? = last {} else { XCTFail("An occupied file must not be announced as remote") }
    }
    func testLocalSecretAndMalformedCloudResourcePathsAreExcludedFromCacheScope() {
        let local = cacheFile(1, resource: LocalFileMediaResource(fileId: 1, size: 8, isSecretRelated: true))
        let cloud = cacheFile(2, resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 2,
            accessHash: 53, size: 8, fileReference: nil, fileName: nil))
        XCTAssertTrue(telegramCacheResources(local).isEmpty)
        XCTAssertEqual(telegramCacheResources(cloud).map(\.id), [cloud.resource.id])
        let bad = CloudPhotoSizeMediaResource(datacenterId: 2, photoId: 3, accessHash: 53,
            sizeSpec: "../../archive", size: 8, fileReference: nil)
        let image = TelegramMediaImage(imageId: .init(namespace: Namespaces.Media.CloudImage, id: 3),
            representations: [.init(dimensions: .init(width: 10, height: 10), resource: bad, progressiveSizes: [], immediateThumbnailData: nil,
                hasVideo: false, isPersonal: false)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        XCTAssertTrue(telegramCacheResources(image).isEmpty)
    }
}

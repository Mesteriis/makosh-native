import XCTest
import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor private final class EmojiCatalogFixture: TelegramCustomEmojiCatalogProvider {
    let accountID: Int64
    let values = ValuePipe<TelegramCustomEmojiCatalogSnapshot>()
    var searches: [String: ValuePipe<TelegramCustomEmojiSearchResult>] = [:]
    var packs: [TelegramStickerPackReference: ValuePipe<TelegramCustomEmojiPackResult>] = [:]
    let mutations = ValuePipe<Bool>()
    init(_ id: Int64) { accountID = id }
    func catalog() -> Signal<TelegramCustomEmojiCatalogSnapshot, NoError> { values.signal() }
    func search(query: String) -> Signal<TelegramCustomEmojiSearchResult, NoError> {
        let pipe = ValuePipe<TelegramCustomEmojiSearchResult>(); searches[query] = pipe; return pipe.signal()
    }
    func loadPack(reference: TelegramStickerPackReference) -> Signal<TelegramCustomEmojiPackResult, NoError> {
        let pipe = ValuePipe<TelegramCustomEmojiPackResult>(); packs[reference] = pipe; return pipe.signal()
    }
    func setInstalled(pack: TelegramCustomEmojiPack, installed: Bool) -> Signal<Bool, NoError> { mutations.signal() }
    func publish(_ tier: TelegramCustomEmojiEntitlement = .standard,
                 recent: [TelegramCustomEmojiDescriptor] = [], installed: [TelegramCustomEmojiPack] = [],
                 featured: [TelegramCustomEmojiPack] = []) {
        values.putNext(.init(accountID: accountID, entitlement: tier, recent: recent, installed: installed, featured: featured))
    }
}
private nonisolated func catalogFile(_ id: Int64, premium: Bool = false) -> TelegramMediaFile {
    TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil,
        resource: CloudDocumentMediaResource(datacenterId: 2, fileId: id, accessHash: 17, size: 100,
            fileReference: Data([1]), fileName: "synthetic.webp"), previewRepresentations: [], videoThumbnails: [],
        immediateThumbnailData: nil, mimeType: "image/webp", size: 100,
        attributes: [.CustomEmoji(isPremium: premium, isSingleColor: false, alt: "🦊", packReference: .id(id: 77, accessHash: 79))],
        alternativeRepresentations: [])
}
private nonisolated func catalogEmoji(_ id: Int64, premium: Bool = false) throws -> TelegramCustomEmojiDescriptor {
    try .init(file: catalogFile(id, premium: premium))
}
private func catalogPack(_ id: Int64, installed: Bool = false, items: [TelegramCustomEmojiDescriptor] = []) -> TelegramCustomEmojiPack {
    .init(id: id, reference: .id(id: id, accessHash: 79), title: "Synthetic \(id)", shortName: "synthetic_\(id)",
        itemCount: items.count, installed: installed, items: items, itemsComplete: true)
}
@MainActor final class TelegramCustomEmojiCatalogTests: XCTestCase {
    // Catches old account descriptors surviving a rebind and gaining pick permission.
    func testRebindClearsOldAccountCatalogAndChangesContext() throws {
        let first = EmojiCatalogFixture(1), second = EmojiCatalogFixture(2), controller = TelegramCustomEmojiCatalogController()
        let old = try catalogEmoji(10), current = try catalogEmoji(20)
        controller.bind(provider: first); first.publish(.premium, recent: [old])
        XCTAssertTrue(controller.canInsert(old, chatID: 42))
        let context = controller.contextID
        controller.bind(provider: second)
        XCTAssertNotEqual(controller.contextID, context); XCTAssertNil(controller.snapshot)
        XCTAssertFalse(controller.canInsert(old, chatID: 42))
        first.publish(.premium, recent: [old]); second.publish(recent: [current])
        XCTAssertEqual(controller.snapshot?.accountID, 2)
        XCTAssertTrue(controller.canInsert(current, chatID: 42)); XCTAssertFalse(controller.canInsert(old, chatID: 42))
    }
    // Catches an unresolved own user, paid item or forged descriptor gaining insertion permission.
    func testInsertionRequiresKnownTierExactMembershipAndSavedMessagesException() throws {
        let provider = EmojiCatalogFixture(1), controller = TelegramCustomEmojiCatalogController()
        let free = try catalogEmoji(10), paid = try catalogEmoji(20, premium: true), forged = try catalogEmoji(20)
        controller.bind(provider: provider); provider.publish(.unknown, recent: [free, paid])
        XCTAssertFalse(controller.canInsert(free, chatID: 42))
        provider.publish(recent: [free, paid])
        XCTAssertTrue(controller.canInsert(free, chatID: 42)); XCTAssertFalse(controller.canInsert(paid, chatID: 42))
        XCTAssertTrue(controller.canInsert(paid, chatID: 1)); XCTAssertFalse(controller.canInsert(forged, chatID: 42))
        provider.publish(.premium, recent: [paid]); XCTAssertTrue(controller.canInsert(paid, chatID: 42))
    }
    // Catches an earlier query republishing stale picks after the user changed or cleared search.
    func testSearchClearsOldResultsAndRetainsPartialThenFinalState() throws {
        let provider = EmojiCatalogFixture(1), controller = TelegramCustomEmojiCatalogController(), first = try catalogEmoji(10), second = try catalogEmoji(20)
        controller.bind(provider: provider); provider.publish()
        controller.search(query: "fox"); provider.searches["fox"]?.putNext(.init(items: [first], isFinal: false))
        XCTAssertEqual(controller.searchResults.map(\.id), [10]); XCTAssertFalse(controller.searchIsFinal)
        controller.search(query: "owl"); XCTAssertTrue(controller.searchResults.isEmpty)
        provider.searches["fox"]?.putNext(.init(items: [first], isFinal: true))
        provider.searches["owl"]?.putNext(.init(items: [second], isFinal: true))
        XCTAssertEqual(controller.searchResults.map(\.id), [20]); XCTAssertTrue(controller.searchIsFinal)
        XCTAssertFalse(controller.canInsert(first, chatID: 42)); XCTAssertTrue(controller.canInsert(second, chatID: 42))
        controller.search(query: ""); provider.searches["owl"]?.putNext(.init(items: [second], isFinal: true))
        XCTAssertTrue(controller.searchResults.isEmpty); XCTAssertTrue(controller.searchIsFinal)
    }
    // Catches an obsolete pack or account detail response replacing the current visible pack.
    func testPackDetailRejectsWrongIdentityAndStaleResponse() throws {
        let provider = EmojiCatalogFixture(1), controller = TelegramCustomEmojiCatalogController()
        let first = catalogPack(77), second = catalogPack(78, items: [try catalogEmoji(20)])
        controller.bind(provider: provider); provider.publish(featured: [first, second])
        controller.loadPack(reference: first.reference); XCTAssertTrue(controller.packIsLoading)
        controller.loadPack(reference: second.reference)
        provider.packs[first.reference]?.putNext(.ready(first))
        provider.packs[second.reference]?.putNext(.ready(first)); XCTAssertNil(controller.selectedPack)
        provider.packs[second.reference]?.putNext(.ready(second))
        XCTAssertEqual(controller.selectedPack?.id, 78); XCTAssertFalse(controller.packIsLoading)
        XCTAssertTrue(controller.canInsert(try catalogEmoji(20), chatID: 42))
        controller.bind(provider: nil); provider.packs[second.reference]?.putNext(.ready(second))
        XCTAssertNil(controller.selectedPack); XCTAssertFalse(controller.packIsLoading)
    }
    // Catches local queue acknowledgement being mistaken for a new authoritative installed catalog.
    func testInstallCompletionKeepsCatalogUntilObservedInstallation() throws {
        let provider = EmojiCatalogFixture(1), controller = TelegramCustomEmojiCatalogController(), pack = catalogPack(77)
        controller.bind(provider: provider); provider.publish(featured: [pack])
        controller.loadPack(reference: pack.reference); provider.packs[pack.reference]?.putNext(.ready(pack))
        controller.setInstalled(true); XCTAssertTrue(controller.mutationIsPending)
        provider.mutations.putNext(true); XCTAssertFalse(controller.mutationIsPending)
        XCTAssertEqual(controller.snapshot?.installed.count, 0); XCTAssertEqual(controller.selectedPack?.installed, false)
        provider.publish(installed: [catalogPack(77, installed: true)])
        XCTAssertEqual(controller.snapshot?.installed.map(\.id), [77])
    }
}

private nonisolated func catalogSeed(_ box: Postbox, user: TelegramUser, info: StickerPackCollectionInfo,
    item: StickerPackItem, file: TelegramMediaFile) -> Signal<Bool, NoError> {
    box.transaction { transaction -> Bool in
            transaction.updatePeersInternal([user], update: { _, value in value })
            transaction.replaceItemCollections(namespace: Namespaces.ItemCollection.CloudEmojiPacks,
                itemCollections: [(info.id, info, [item])])
            transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.LocalRecentEmoji, items: [
                .init(id: MemoryBuffer(data: Data([1])), contents: CodableEntry(RecentEmojiItem(.file(file)))!),
                .init(id: MemoryBuffer(data: Data([2])), contents: CodableEntry(RecentEmojiItem(.text("ordinary")))!)])
            return true
    }
}
private nonisolated func catalogOwnPeer(_ box: Postbox) -> Signal<Peer?, NoError> {
    box.transaction { $0.getPeer(PeerId(1)) }
}

@MainActor final class TelegramCustomEmojiCatalogNativeTests: TelegramSourceFactsIntegrationTestCase {
    // Catches native cached pack/recent conversion losing pack identity, claiming
    // preview completeness, guessing Premium or promoting ordinary text to emoji.
    func testEncryptedNativeCatalogPreservesPackIdentityAndIncompletePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = try await sourceFactsOpen(root.appendingPathComponent("postbox"))
        let file = catalogFile(10), packID = ItemCollectionId(namespace: Namespaces.ItemCollection.CloudEmojiPacks, id: 77)
        let info = StickerPackCollectionInfo(id: packID, flags: [.isEmoji], accessHash: 79,
            title: "Synthetic emoji", shortName: "synthetic_emoji", thumbnail: nil, thumbnailFileId: nil,
            immediateThumbnailData: nil, hash: 0, count: 3)
        let item = StickerPackItem(index: .init(index: 0, id: 10), file: file, indexKeys: [])
        let user = TelegramUser(id: PeerId(1), accessHash: nil, firstName: "Synthetic", lastName: nil,
            username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [.isPremium],
            emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
            profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        _ = try await sourceFactsValue(catalogSeed(box, user: user, info: info, item: item, file: file))
        let view = try await sourceFactsValue(box.itemCollectionsView(
            orderedItemListCollectionIds: [Namespaces.OrderedItemList.LocalRecentEmoji],
            namespaces: [Namespaces.ItemCollection.CloudEmojiPacks], aroundIndex: nil, count: 8000))
        let peer = try await sourceFactsValue(catalogOwnPeer(box))
        let featured = [FeaturedStickerPackItem(info: .init(info), topItems: [item], unread: false)]
        let current = telegramCustomEmojiCatalogSnapshot(accountID: 1, peer: peer, view: view, featured: featured)
        XCTAssertEqual(current.entitlement, .premium); XCTAssertEqual(current.recent.map(\.id), [10])
        let installed = try XCTUnwrap(current.installed.first)
        XCTAssertEqual(installed.reference, .id(id: 77, accessHash: 79)); XCTAssertEqual(installed.items.map(\.id), [10])
        XCTAssertEqual(installed.itemCount, 3); XCTAssertFalse(installed.itemsComplete); XCTAssertTrue(installed.installed)
        let preview = try XCTUnwrap(current.featured.first)
        XCTAssertEqual(preview.reference, .id(id: 77, accessHash: 79)); XCTAssertTrue(preview.installed)
        XCTAssertFalse(preview.itemsComplete)
        XCTAssertEqual(telegramCustomEmojiCatalogSnapshot(accountID: 2, peer: peer, view: view, featured: []).entitlement, .unknown)
        XCTAssertEqual(telegramCustomEmojiCatalogSnapshot(accountID: 1, peer: nil, view: view, featured: []).entitlement, .unknown)
    }
}

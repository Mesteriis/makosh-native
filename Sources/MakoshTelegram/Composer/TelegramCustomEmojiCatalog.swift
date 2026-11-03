import Foundation
import Combine
import TelegramCore
import Postbox
import SwiftSignalKit

public enum TelegramCustomEmojiEntitlement: Equatable, Sendable { case unknown, standard, premium }
public struct TelegramCustomEmojiPack: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let reference: TelegramStickerPackReference
    public let title: String
    public let shortName: String
    public let itemCount: Int
    public let installed: Bool
    public let items: [TelegramCustomEmojiDescriptor]
    public let itemsComplete: Bool
}
public struct TelegramCustomEmojiCatalogSnapshot: Equatable, Sendable {
    public let accountID: Int64
    public let entitlement: TelegramCustomEmojiEntitlement
    public let recent: [TelegramCustomEmojiDescriptor]
    public let installed: [TelegramCustomEmojiPack]
    public let featured: [TelegramCustomEmojiPack]
}
struct TelegramCustomEmojiSearchResult {
    let items: [TelegramCustomEmojiDescriptor]
    let isFinal: Bool
}
enum TelegramCustomEmojiPackResult { case loading, unavailable, ready(TelegramCustomEmojiPack) }
@MainActor protocol TelegramCustomEmojiCatalogProvider: AnyObject {
    var accountID: Int64 { get }
    func catalog() -> Signal<TelegramCustomEmojiCatalogSnapshot, NoError>
    func search(query: String) -> Signal<TelegramCustomEmojiSearchResult, NoError>
    func loadPack(reference: TelegramStickerPackReference) -> Signal<TelegramCustomEmojiPackResult, NoError>
    func setInstalled(pack: TelegramCustomEmojiPack, installed: Bool) -> Signal<Bool, NoError>
}
@MainActor public final class TelegramCustomEmojiCatalogController: ObservableObject {
    @Published public private(set) var snapshot: TelegramCustomEmojiCatalogSnapshot?
    @Published public private(set) var searchResults: [TelegramCustomEmojiDescriptor] = []
    @Published public private(set) var searchIsFinal = true
    @Published public private(set) var selectedPack: TelegramCustomEmojiPack?
    @Published public private(set) var packIsLoading = false
    @Published public private(set) var mutationIsPending = false
    public private(set) var contextID = UUID()
    private var provider: (any TelegramCustomEmojiCatalogProvider)?
    private let catalogSubscription = MetaDisposable(), searchSubscription = MetaDisposable()
    private let packSubscription = MetaDisposable(), mutationSubscription = MetaDisposable()
    private var searchID = UUID(), packID = UUID(), mutationID = UUID()
    public init() {}
    isolated deinit {
        catalogSubscription.dispose(); searchSubscription.dispose()
        packSubscription.dispose(); mutationSubscription.dispose()
    }
    func bind(account: Account?) {
        bind(provider: account.map { TelegramCustomEmojiEngineCatalogProvider(account: $0) })
    }
    func bind(provider: (any TelegramCustomEmojiCatalogProvider)?) {
        contextID = UUID(); searchID = UUID(); packID = UUID(); mutationID = UUID()
        catalogSubscription.set(nil); searchSubscription.set(nil)
        packSubscription.set(nil); mutationSubscription.set(nil)
        snapshot = nil; searchResults = []; searchIsFinal = true
        selectedPack = nil; packIsLoading = false; mutationIsPending = false
        self.provider = provider
        guard let provider else { return }
        let context = contextID, account = provider.accountID
        catalogSubscription.set(provider.catalog().start(next: { [weak self] value in
            MainActor.assumeIsolated {
                guard let self, self.contextID == context, self.provider?.accountID == account,
                      value.accountID == account else { return }
                self.snapshot = value
            }
        }))
    }
    public func search(query: String) {
        searchID = UUID(); searchSubscription.set(nil); searchResults = []; searchIsFinal = true
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provider, !query.isEmpty, query.utf16.count <= 256 else { return }
        searchIsFinal = false
        let context = contextID, account = provider.accountID, request = searchID
        searchSubscription.set(provider.search(query: query).start(next: { [weak self] value in
            MainActor.assumeIsolated {
                guard let self, self.contextID == context, self.searchID == request,
                      self.provider?.accountID == account else { return }
                self.searchResults = value.items; self.searchIsFinal = value.isFinal
            }
        }))
    }
    public func loadPack(reference: TelegramStickerPackReference) {
        packID = UUID(); mutationID = UUID()
        packSubscription.set(nil); mutationSubscription.set(nil)
        selectedPack = nil; mutationIsPending = false; packIsLoading = false
        guard let provider else { return }
        packIsLoading = true
        let context = contextID, account = provider.accountID, request = packID
        packSubscription.set(provider.loadPack(reference: reference).start(next: { [weak self] value in
            MainActor.assumeIsolated {
                guard let self, self.contextID == context, self.packID == request,
                      self.provider?.accountID == account else { return }
                switch value {
                case .loading: self.packIsLoading = true
                case .unavailable: self.packIsLoading = false; self.selectedPack = nil
                case let .ready(pack):
                    self.packIsLoading = false
                    guard telegramCustomEmojiPackMatches(pack, reference: reference) else { return }
                    self.selectedPack = pack
                }
            }
        }))
    }
    public func setInstalled(_ installed: Bool) {
        guard let provider, let pack = selectedPack, pack.itemsComplete, !mutationIsPending else { return }
        mutationID = UUID(); mutationSubscription.set(nil); mutationIsPending = true
        let context = contextID, account = provider.accountID, request = mutationID, selected = packID
        mutationSubscription.set((provider.setInstalled(pack: pack, installed: installed) |> take(1)).start(next: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.contextID == context, self.mutationID == request,
                      self.packID == selected, self.provider?.accountID == account else { return }
                // The native operation queues local synchronization. Only the
                // observed catalog establishes the installed state shown above.
                self.mutationIsPending = false
            }
        }))
    }
    public func canInsert(_ descriptor: TelegramCustomEmojiDescriptor, chatID: Int64) -> Bool {
        guard let snapshot, snapshot.accountID == provider?.accountID,
              snapshot.entitlement != .unknown else { return false }
        let candidates = snapshot.recent + snapshot.installed.flatMap(\.items) +
            snapshot.featured.flatMap(\.items) + searchResults + (selectedPack?.items ?? [])
        guard candidates.contains(descriptor) else { return false }
        return !descriptor.isPremium || snapshot.entitlement == .premium || chatID == snapshot.accountID
    }
}

nonisolated func telegramCustomEmojiPackMatches(_ pack: TelegramCustomEmojiPack,
    reference: TelegramStickerPackReference) -> Bool {
    if case let .name(name) = reference { return pack.shortName.caseInsensitiveCompare(name) == .orderedSame }
    return pack.reference == reference
}
nonisolated func telegramCustomEmojiPack(info: StickerPackCollectionInfo, items: [StickerPackItem],
    installed: Bool, previewLimit: Int = 40) -> TelegramCustomEmojiPack? {
    guard info.id.namespace == Namespaces.ItemCollection.CloudEmojiPacks,
          info.flags.contains(.isEmoji), info.count >= 0 else { return nil }
    let descriptors = items.compactMap { try? TelegramCustomEmojiDescriptor(file: $0.file._parse()) }
    let complete = descriptors.count == items.count && descriptors.count == Int(info.count)
    return .init(id: info.id.id, reference: .id(id: info.id.id, accessHash: info.accessHash),
        title: info.title, shortName: info.shortName, itemCount: Int(info.count), installed: installed,
        items: Array(descriptors.prefix(previewLimit)), itemsComplete: complete && descriptors.count <= previewLimit)
}
nonisolated func telegramCustomEmojiCatalogSnapshot(accountID: Int64, peer: Peer?, view: ItemCollectionsView,
    featured: [FeaturedStickerPackItem]) -> TelegramCustomEmojiCatalogSnapshot {
    let entitlement: TelegramCustomEmojiEntitlement
    if let user = peer as? TelegramUser, user.id == PeerId(accountID),
       user.id.namespace == Namespaces.Peer.CloudUser {
        entitlement = user.flags.contains(.isPremium) ? .premium : .standard
    } else { entitlement = .unknown }
    let recent = view.orderedItemListsViews.filter { $0.collectionId == Namespaces.OrderedItemList.LocalRecentEmoji }
        .flatMap(\.items).compactMap { entry -> TelegramCustomEmojiDescriptor? in
            guard let recent = entry.contents.get(RecentEmojiItem.self), case let .file(file) = recent.content else { return nil }
            return try? TelegramCustomEmojiDescriptor(file: file)
        }
    let installed = view.collectionInfos.compactMap { id, value, _ -> TelegramCustomEmojiPack? in
        guard let info = value as? StickerPackCollectionInfo else { return nil }
        let items = view.entries.filter { $0.index.collectionId == id }.compactMap { $0.item as? StickerPackItem }
        return telegramCustomEmojiPack(info: info, items: items, installed: true)
    }
    let installedIDs = Set(installed.map(\.id))
    return .init(accountID: accountID, entitlement: entitlement, recent: recent, installed: installed,
        featured: featured.compactMap { value in
            let info = value.info._parse()
            return telegramCustomEmojiPack(info: info, items: value.topItems, installed: installedIDs.contains(info.id.id))
        })
}

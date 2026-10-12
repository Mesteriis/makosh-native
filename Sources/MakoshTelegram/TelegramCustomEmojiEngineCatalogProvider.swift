import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

@MainActor final class TelegramCustomEmojiEngineCatalogProvider: TelegramCustomEmojiCatalogProvider {
    let accountID: Int64
    private let account: Account
    private let engine: TelegramEngine
    private var loaded: [Int64: (TelegramCustomEmojiPack, StickerPackCollectionInfo, [StickerPackItem])] = [:]
    init(account: Account) {
        self.account = account; self.accountID = account.peerId.toInt64(); self.engine = TelegramEngine(account: account)
    }
    func catalog() -> Signal<TelegramCustomEmojiCatalogSnapshot, NoError> {
        telegramCustomEmojiEngineCatalogSignal(account: account)
    }
    func search(query: String) -> Signal<TelegramCustomEmojiSearchResult, NoError> {
        telegramCustomEmojiEngineSearchSignal(engine: engine, query: query)
    }
    func loadPack(reference: TelegramStickerPackReference) -> Signal<TelegramCustomEmojiPackResult, NoError> {
        // The existing native entity mapping preserves every typed pack case.
        guard let formatted = try? TelegramFormattedText(text: "😀", entities: [
            .init(offset: 0, length: 2, kind: .customEmoji(stickerPack: reference, fileID: 1))]),
              case let .CustomEmoji(native?, _)? = formatted.engineEntities().first?.type else { return .single(.unavailable) }
        return engine.stickers.loadedStickerPack(reference: native, forceActualized: false)
            |> deliverOnMainQueue
            |> map { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self else { return .unavailable }
                    switch value {
                    case .fetching: return .loading
                    case .none: return .unavailable
                    case let .result(accessor, items, installed):
                        let info = accessor._parse()
                        guard let pack = telegramCustomEmojiPack(info: info, items: items, installed: installed,
                            previewLimit: 8000), telegramCustomEmojiPackMatches(pack, reference: reference) else { return .unavailable }
                        self.loaded[pack.id] = (pack, info, items)
                        return .ready(pack)
                    }
                }
            }
    }
    func setInstalled(pack: TelegramCustomEmojiPack, installed: Bool) -> Signal<Bool, NoError> {
        guard let cached = loaded[pack.id], cached.0 == pack, pack.itemsComplete else { return .single(false) }
        if installed {
            return engine.stickers.addStickerPackInteractively(info: cached.1, items: cached.2)
                |> deliverOnMainQueue |> map { _ in true }
        } else {
            return engine.stickers.removeStickerPackInteractively(id: cached.1.id, option: .delete)
                |> deliverOnMainQueue |> map { $0 != nil }
        }
    }
}

private nonisolated func telegramCustomEmojiEngineCatalogSignal(account: Account)
    -> Signal<TelegramCustomEmojiCatalogSnapshot, NoError> {
    let accountID = account.peerId.toInt64()
    return combineLatest(account.postbox.itemCollectionsView(
        orderedItemListCollectionIds: [Namespaces.OrderedItemList.LocalRecentEmoji],
        namespaces: [Namespaces.ItemCollection.CloudEmojiPacks], aroundIndex: nil, count: 8000),
        account.viewTracker.featuredEmojiPacks(), account.viewTracker.peerView(account.peerId, updateData: false))
        |> map { view, featured, peerView in
            telegramCustomEmojiCatalogSnapshot(accountID: accountID, peer: peerView.peers[PeerId(accountID)],
                view: view, featured: featured)
        } |> deliverOnMainQueue
}
private nonisolated func telegramCustomEmojiEngineSearchSignal(engine: TelegramEngine, query: String)
    -> Signal<TelegramCustomEmojiSearchResult, NoError> {
    engine.stickers.searchEmoji(query: query, emoticon: [], inputLanguageCode: "")
        |> map { value in .init(items: value.items.compactMap { try? TelegramCustomEmojiDescriptor(file: $0) },
                                isFinal: value.isFinalResult) }
        |> deliverOnMainQueue
}

import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

nonisolated func telegramCacheSnapshot(transaction: Transaction, stats: CacheUsageStats, accountID: Int64) -> TelegramCacheSnapshot? {
    guard stats.media.count <= 10_000, stats.mediaResourceIds.count <= 10_000 else { return nil }
    var catalogue: [MediaId: (TelegramCacheKind, Int64)] = [:], count = 0
    for categories in stats.media.values {
        for (category, values) in categories {
            let kind: TelegramCacheKind
            switch category { case .image: kind = .photos; case .video: kind = .videos; case .audio: kind = .audio; case .file: kind = .files }
            for (id, bytes) in values {
                count += 1; guard count <= 100_000, bytes >= 0 else { return nil }
                if let old = catalogue[id] {
                    guard old.0 == kind else { return nil }; catalogue[id] = (kind, max(old.1, bytes))
                } else { catalogue[id] = (kind, bytes) }
                guard catalogue.count <= 10_000 else { return nil }
            }
        }
    }
    var items: [TelegramCacheItem] = []
    for (id, value) in catalogue.sorted(by: { $0.key.namespace == $1.key.namespace ? $0.key.id < $1.key.id : $0.key.namespace < $1.key.namespace }) {
        guard let media = transaction.getMedia(id), let observed = stats.mediaResourceIds[id], observed.count <= 10_000 else { continue }
        let ids = Set(observed), allowed = Set(telegramCacheResources(media).map(\.id))
        guard value.1 > 0, !ids.isEmpty, ids.isSubset(of: allowed) else { continue }
        items.append(.init(namespace: id.namespace, id: id.id, bytes: value.1, kind: value.0,
            resources: ids.map(\.stringRepresentation).sorted()))
    }
    let snapshot = TelegramCacheSnapshot(accountID: accountID, items: items)
    return snapshot.isValid ? snapshot : nil
}

nonisolated func telegramReadCache(account: Account) -> Signal<TelegramCacheSnapshot?, NoError> {
    TelegramEngine(account: account).resources.collectCacheUsageStats()
        |> mapToSignal { result -> Signal<TelegramCacheSnapshot?, NoError> in
            guard case let .result(stats) = result else { return .complete() }
            return account.postbox.transaction { telegramCacheSnapshot(transaction: $0, stats: stats, accountID: account.peerId.toInt64()) }
        }
}

nonisolated func telegramResolveCacheSelection(postbox: Postbox, expected: TelegramCacheSnapshot,
    categories: Set<TelegramCacheKind>) -> Signal<[Media]?, NoError> {
    postbox.transaction { transaction in
        guard expected.isValid, !categories.isEmpty else { return nil }
        var media: [Media] = []
        for item in expected.items where categories.contains(item.kind) {
            guard let current = transaction.getMedia(MediaId(namespace: item.namespace, id: item.id)),
                  Set(item.resources.map(MediaResourceId.init)).isSubset(of: Set(telegramCacheResources(current).map(\.id))) else { return nil }
            media.append(current)
        }
        return media
    }
}

nonisolated func telegramCacheResources(_ media: Media) -> [MediaResource] {
    var resources: [MediaResource] = []
    if let file = media as? TelegramMediaFile {
        resources.append(file.resource); resources += file.previewRepresentations.map(\.resource)
    } else if let image = media as? TelegramMediaImage {
        resources += image.representations.map(\.resource)
    }
    var seen = Set<MediaResourceId>()
    return resources.filter { resource in
        guard resource is CloudDocumentMediaResource || resource is CloudPhotoSizeMediaResource ||
              resource is CloudDocumentSizeMediaResource || resource is CloudFileMediaResource else { return false }
        let id = resource.id.stringRepresentation
        guard telegramCacheResourceIDIsValid(id) else { return false }
        return seen.insert(resource.id).inserted
    }
}
nonisolated func telegramRemoveCloudCache(mediaBox: MediaBox, media: [Media],
    restrictingTo: Set<MediaResourceId>) -> Signal<[MediaResourceId], NoError> {
    guard media.count <= 10_000, restrictingTo.count <= 10_000 else { return .single([]) }
    let ids = Set(media.flatMap(telegramCacheResources).map(\.id)).intersection(restrictingTo)
    return mediaBox.removeCachedResourcesWithResult(ids.sorted { $0.stringRepresentation < $1.stringRepresentation }, force: false, notify: true)
}

import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

nonisolated func telegramCacheSnapshot(transaction: Transaction, stats: CacheUsageStats, accountID: Int64, modificationTime: ((String) -> Int64?)? = nil) -> TelegramCacheSnapshot? {
    guard stats.media.count <= 10_000, stats.mediaResourceIds.count <= 10_000 else { return nil }
    var resourceCount = 0
    for ids in stats.mediaResourceIds.values {
        guard ids.count <= 10_000, resourceCount <= 100_000 - ids.count,
              ids.allSatisfy({ telegramCacheResourceIDIsValid($0.stringRepresentation) }) else { return nil }
        resourceCount += ids.count
    }
    var catalogue: [MediaId:(TelegramCacheKind,Int64,Set<Int64>)] = [:], count = 0
    var excluded = Set<MediaId>()
    for (peer,categories) in stats.media {
        let allowed = peer.namespace == Namespaces.Peer.CloudUser || peer.namespace == Namespaces.Peer.CloudGroup || peer.namespace == Namespaces.Peer.CloudChannel
        for (category,values) in categories {
            let kind: TelegramCacheKind
            switch category { case .image: kind = .photos; case .video: kind = .videos; case .audio: kind = .audio; case .file: kind = .files }
            for (id,bytes) in values {
                count += 1; guard count <= 100_000, bytes >= 0 else { return nil }
                if !allowed { excluded.insert(id); continue }
                if let old = catalogue[id] {
                    guard old.0 == kind else { return nil }; catalogue[id] = (kind,max(old.1,bytes),old.2.union([peer.toInt64()]))
                } else { catalogue[id] = (kind,bytes,[peer.toInt64()]) }
                guard catalogue.count <= 10_000 else { return nil }
            }
        }
    }
    let excludedResources = Set(excluded.flatMap { stats.mediaResourceIds[$0] ?? [] })
    var items: [TelegramCacheItem] = []
    for (id, value) in catalogue.sorted(by: { $0.key.namespace == $1.key.namespace ? $0.key.id < $1.key.id : $0.key.namespace < $1.key.namespace }) {
        guard !excluded.contains(id), let media = transaction.getMedia(id), let observed = stats.mediaResourceIds[id], observed.count <= 10_000 else { continue }
        let ids = Set(observed), allowed = Set(telegramCacheResources(media).map(\.id))
        guard value.1 > 0, !ids.isEmpty, ids.isSubset(of: allowed), ids.isDisjoint(with:excludedResources) else { continue }
        let resources = ids.map(\.stringRepresentation).sorted()
        let times = resources.compactMap { modificationTime?($0) }.filter { $0 > 0 }
        items.append(.init(namespace: id.namespace, id: id.id, bytes: value.1, kind: value.0,
            resources: resources,peerIDs:value.2.sorted(),modifiedAt:times.count == resources.count ? times.max() : nil))
    }
    var titles: [Int64:String] = [:]
    for id in Set(items.flatMap(\.peerIDs)) {
        let peerID = PeerId(id)
        let title = (transaction.getPeer(peerID) ?? stats.peers[peerID]).map(telegramPeerTitle)
        titles[id] = title.flatMap { !$0.isEmpty && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where:{ $0.value < 32 || $0.value == 127 }) ? $0 : nil } ?? "Чат \(id)"
    }
    let snapshot = TelegramCacheSnapshot(accountID: accountID, items: items,peerTitles:titles)
    return snapshot.isValid ? snapshot : nil
}

nonisolated func telegramReadCache(account: Account) -> Signal<TelegramCacheSnapshot?, NoError> {
    TelegramEngine(account: account).resources.collectCacheUsageStats()
        |> mapToSignal { result -> Signal<TelegramCacheSnapshot?, NoError> in
            guard case let .result(stats) = result else { return .complete() }
            return account.postbox.transaction { telegramCacheSnapshot(transaction: $0, stats: stats, accountID: account.peerId.toInt64(),modificationTime:{ id in
                let value = account.postbox.mediaBox.resourceUsageWithInfo(id:MediaResourceId(id))
                return value > 0 ? Int64(value) : nil
            }) }
        }
}

nonisolated func telegramResolveCacheSelection(postbox: Postbox, expected: TelegramCacheSnapshot,
    categories: Set<TelegramCacheKind>, scope: TelegramCacheScope = .all) -> Signal<[Media]?, NoError> {
    postbox.transaction { transaction in
        guard expected.isValid, !categories.isEmpty, scope.isValid else { return nil }
        var media: [Media] = []
        for item in expected.selectedItems(categories:categories,scope:scope) {
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

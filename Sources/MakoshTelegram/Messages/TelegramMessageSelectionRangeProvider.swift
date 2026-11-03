import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

@MainActor protocol TelegramMessageSelectionRangeProvider: AnyObject {
    var accountID: Int64 { get }
    func resolve(request: TelegramMessageSelectionRangeRequest,
                 completion: @escaping @MainActor ([TelegramMessageActionSource]) -> Void) -> Disposable
}

/// The reference adds cached numeric IDs in descending order, preferring Cloud
/// over Local for the same number. Two bounded native index reads avoid scanning
/// every missing integer or allocating the entire cached history.
func telegramSelectionRange(postbox: Postbox, accountID: Int64,
                            request: TelegramMessageSelectionRangeRequest) -> Signal<[TelegramMessageActionSource], NoError> {
    postbox.transaction { transaction in
        guard request.accountID == accountID, request.anchorID.peerID == request.endpointID.peerID,
              request.anchorID.peerID == request.chatID, request.lowerBound > 0,
              request.lowerBound < request.upperBoundExclusive else { return [] }
        let peer = PeerId(request.anchorID.peerID)
        let cloud = transaction.makoshCachedMessageIds(peerId: peer, namespace: Namespaces.Message.Cloud,
            lowerBound: request.lowerBound, upperBoundExclusive: request.upperBoundExclusive, limit: 200)
        let local = transaction.makoshCachedMessageIds(peerId: peer, namespace: Namespaces.Message.Local,
            lowerBound: request.lowerBound, upperBoundExclusive: request.upperBoundExclusive, limit: 200)
        let ordered = (cloud + local).sorted {
            $0.id == $1.id ? $0.namespace < $1.namespace : $0.id > $1.id
        }
        var seen = Set<Int32>(), result: [TelegramMessageActionSource] = []
        let limits = currentLimitsConfiguration(transaction: transaction)
        for id in ordered {
            guard !seen.contains(id.id), let message = transaction.getMessage(id) else { continue }
            seen.insert(id.id)
            result.append(.init(metadata: telegramMessageActionMetadata(message, limits: limits),
                accountID: accountID, chatID: request.chatID))
            if result.count == 200 { break }
        }
        return result
    }
}

@MainActor final class TelegramPostboxSelectionRangeProvider: TelegramMessageSelectionRangeProvider {
    let accountID: Int64
    private let postbox: Postbox
    init(postbox: Postbox, accountID: Int64) { self.postbox = postbox; self.accountID = accountID }
    func resolve(request: TelegramMessageSelectionRangeRequest,
                 completion: @escaping @MainActor ([TelegramMessageActionSource]) -> Void) -> Disposable {
        (telegramSelectionRange(postbox: postbox, accountID: accountID, request: request) |> deliverOnMainQueue)
            .start(next: { value in MainActor.assumeIsolated { completion(value) } })
    }
}

#if DEBUG
@MainActor final class TelegramSyntheticSelectionRangeProvider: TelegramMessageSelectionRangeProvider {
    let accountID: Int64 = -1
    private let pages: TelegramSyntheticPages
    init(pages: TelegramSyntheticPages = .init()) { self.pages = pages }
    func resolve(request: TelegramMessageSelectionRangeRequest,
                 completion: @escaping @MainActor ([TelegramMessageActionSource]) -> Void) -> Disposable {
        guard request.accountID == accountID, request.anchorID.peerID == request.endpointID.peerID,
              request.anchorID.peerID == request.chatID else { completion([]); return EmptyDisposable }
        var anchor: MessageIndex?, sources: [TelegramMessageActionSource] = []
        repeat {
            let page = pages.messages(chatID: request.chatID, anchor: anchor)
            sources += page.items.compactMap { item in
                guard let metadata = item.actionMetadata, metadata.messageID >= request.lowerBound,
                      metadata.messageID < request.upperBoundExclusive else { return nil }
                return TelegramMessageActionSource(metadata: metadata, accountID: accountID, chatID: request.chatID)
            }
            anchor = page.previous
        } while anchor != nil
        completion(Array(sources.sorted { $0.messageID > $1.messageID }.prefix(200)))
        return EmptyDisposable
    }
}
#endif

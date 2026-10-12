import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// A local lookup, with fresh capabilities and migration ownership. Resolving a
/// draft never fetches a message or synchronizes a draft with Telegram servers.
func telegramComposerReply(postbox: Postbox, accountID: Int64, target: TelegramComposerReplyTarget,
                           chatID: Int64) -> Signal<TelegramComposerReply?, NoError> {
    postbox.transaction { transaction in
        guard target.isValid,
              let message = transaction.getMessage(MessageId(peerId: PeerId(target.peerID),
                namespace: target.namespace, id: target.messageID)) else { return nil }
        guard let source = TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message,
            limits: currentLimitsConfiguration(transaction: transaction)), accountID: accountID, chatID: chatID)
            .quoting(target.quote, maximumLength: telegramReplyQuoteLimit(transaction: transaction)) else { return nil }
        guard source.canReply, TelegramComposerReplyTarget(source: source) == target,
              source.peerID == chatID || source.metadata.migrationChatID == chatID else { return nil }
        if source.peerID != chatID {
            guard let group = transaction.getPeer(message.id.peerId) as? TelegramGroup,
                  group.migrationReference?.peerId == PeerId(chatID) else { return nil }
        }
        return TelegramComposerReply(source: source, author: message.author.map(telegramPeerTitle) ?? "Сообщение")
    }
}

@MainActor final class TelegramPostboxComposerReplyProvider: TelegramComposerReplyProvider {
    let accountID: Int64
    private let postbox: Postbox
    init(postbox: Postbox, accountID: Int64) { self.postbox = postbox; self.accountID = accountID }
    func resolve(target: TelegramComposerReplyTarget, chatID: Int64,
                 completion: @escaping @MainActor (TelegramComposerReply?) -> Void) -> Disposable {
        (telegramComposerReply(postbox: postbox, accountID: accountID, target: target, chatID: chatID)
            |> deliverOnMainQueue).start(next: { value in MainActor.assumeIsolated { completion(value) } })
    }
}

#if DEBUG
@MainActor final class TelegramSyntheticComposerReplyProvider: TelegramComposerReplyProvider {
    let accountID: Int64 = -1
    private let pages: TelegramSyntheticPages
    init(pages: TelegramSyntheticPages = .init()) { self.pages = pages }
    func resolve(target: TelegramComposerReplyTarget, chatID: Int64,
                 completion: @escaping @MainActor (TelegramComposerReply?) -> Void) -> Disposable {
        let anchor = MessageIndex(id: MessageId(peerId: PeerId(target.peerID), namespace: target.namespace,
            id: target.messageID), timestamp: 0)
        let value = pages.messages(chatID: chatID, anchor: anchor).items.first { item in
            guard let metadata = item.actionMetadata else { return false }
            return TelegramMessageActionSource(metadata: metadata, accountID: accountID, chatID: chatID)
                .quoting(target.quote).map(TelegramComposerReplyTarget.init(source:)) == target
        }.flatMap { item -> TelegramComposerReply? in
            guard let metadata = item.actionMetadata else { return nil }
            guard let source = TelegramMessageActionSource(metadata: metadata,
                accountID: accountID, chatID: chatID).quoting(target.quote) else { return nil }
            return TelegramComposerReply(source: source, author: item.author)
        }
        completion(value)
        return EmptyDisposable
    }
}
#endif

import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

typealias TelegramNativeEnqueueOperation = ([EnqueueMessage], @escaping (Transaction) -> Bool,
    @escaping (Transaction, [MessageId?]) -> Void) -> Signal<[MessageId?], NoError>

/// A nil result is an unconfirmed outcome; an empty result is known rejection.
nonisolated func telegramNativePreparedEnqueue(preparation: TelegramNativeSendPreparation,
    authorization: TelegramSendAuthorizationReceipt, specificAdmission: @escaping (Transaction) -> Bool,
    specificCommit: @escaping (Transaction, [MessageId?]) -> Void = { _, _ in },
    enqueue: @escaping TelegramNativeEnqueueOperation) -> Signal<[MessageId?]?, NoError> {
    guard preparation.context == authorization.context else { return .single([]) }
    let admitted = Atomic(value: false), acknowledged = Atomic<[MessageId?]?>(value: nil)
    let admission = authorization.admission(messages: preparation.messages,
        specificAdmission: { transaction in
            guard preparation.validate(transaction: transaction), specificAdmission(transaction) else { return false }
            return true
        })
    return enqueue(preparation.messages, { transaction in
        guard admission(transaction) else { return false }
        _ = admitted.swap(true); return true
    }, { transaction, ids in
            guard authorization.acknowledge(transaction: transaction, messageIDs: ids) else { return }
            specificCommit(transaction, ids)
            _ = acknowledged.swap(ids)
        }) |> map { ids in
            if ids.isEmpty { return admitted.with({ $0 }) ? nil : [] }
            guard acknowledged.with({ $0 }) == ids else { return nil }
            return ids
        }
}

@MainActor func telegramApprovalForDestination(account: Account, approval: TelegramSendApprovalController,
    context: TelegramSendContext, title: String? = nil,
    onApproved: @escaping @MainActor () -> Void = {})
    -> Signal<Result<TelegramPaidSendConsent?, TelegramSendApprovalError>, NoError> {
    let titles = title.map { Signal<String, NoError>.single($0) }
        ?? telegramDestinationTitle(postbox: account.postbox, chatID: context.chatID)
    return (titles |> deliverOnMainQueue) |> mapToSignal { title in
        Signal { subscriber in
            let lease = MetaDisposable()
            MainActor.assumeIsolated {
                lease.set(telegramSendApprovalSignal(controller: approval, context: context, title: title)
                    .start(next: { value in
                        MainActor.assumeIsolated { if case .success = value { onApproved() } }
                        subscriber.putNext(value); subscriber.putCompletion() }))
            }
            return lease
        }
    }
}

@MainActor func telegramApprovedEnqueue(account: Account, approval: TelegramSendApprovalController,
    context: TelegramSendContext, title: String? = nil, messages: [EnqueueMessage],
    onApproved: @escaping @MainActor () -> Void = {},
    specificAdmission: @escaping (Transaction) -> Bool = { _ in true },
    specificCommit: @escaping (Transaction, [MessageId?]) -> Void = { _, _ in }) -> Signal<[MessageId?]?, NoError> {
    let consent = telegramApprovalForDestination(account: account, approval: approval, context: context, title: title, onApproved: onApproved)
    return telegramEnqueueAfterApproval(account: account, context: context, messages: messages,
        approval: consent, specificAdmission: specificAdmission, specificCommit: specificCommit)
}

nonisolated func telegramEnqueueAfterApproval(account: Account, context: TelegramSendContext,
    messages: [EnqueueMessage], approval: Signal<Result<TelegramPaidSendConsent?, TelegramSendApprovalError>, NoError>,
    specificAdmission: @escaping (Transaction) -> Bool,
    specificCommit: @escaping (Transaction, [MessageId?]) -> Void) -> Signal<[MessageId?]?, NoError> {
    approval |> mapToSignal { result -> Signal<[MessageId?]?, NoError> in
        guard case let .success(consent) = result else { return .single([]) }
        return telegramEnqueueApprovedMessages(account: account, context: context, messages: messages,
            consent: consent, specificAdmission: specificAdmission, specificCommit: specificCommit)
    }
}

nonisolated func telegramEnqueueApprovedMessages(account: Account, context: TelegramSendContext,
    messages: [EnqueueMessage], consent: TelegramPaidSendConsent?,
    specificAdmission: @escaping (Transaction) -> Bool = { _ in true },
    specificCommit: @escaping (Transaction, [MessageId?]) -> Void = { _, _ in }) -> Signal<[MessageId?]?, NoError> {
    telegramResolveNativeSendPreparation(account: account, context: context, messages: messages, consent: consent)
        |> mapToSignal { preparation -> Signal<[MessageId?]?, NoError> in
            guard let preparation else { return .single([]) }
            return telegramNativePreparedEnqueue(preparation: preparation,
                authorization: .init(context: context, consent: consent), specificAdmission: specificAdmission,
                specificCommit: specificCommit) { messages, admission, commit in
                    enqueueMessages(account: account, peerId: PeerId(context.chatID), messages: messages,
                        transactionAdmission: admission, transactionCommit: commit)
                }
        }
}

nonisolated func telegramResolveNativeSendPreparation(account: Account, context: TelegramSendContext,
    messages: [EnqueueMessage], consent: TelegramPaidSendConsent?) -> Signal<TelegramNativeSendPreparation?, NoError> {
    let ids = Set(messages.flatMap { message in
        message.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.flatMap(\.entities)
            .compactMap { entity -> Int64? in
                if case let .CustomEmoji(_, id) = entity.type { return id }; return nil
            }
    })
    guard ids.count <= 1024 else { return .single(nil) }
    let files = ids.isEmpty ? Signal<[Int64: TelegramMediaFile], NoError>.single([:])
        : TelegramEngine(account: account).stickers.resolveInlineStickers(fileIds: Array(ids))
    return (files |> take(1) |> mapToSignal { files in
        account.postbox.transaction { transaction in
            telegramNativeSendPreparation(transaction: transaction, context: context,
                messages: messages, files: files.filter { ids.contains($0.key) }, consent: consent)
        }
    }) |> timeout(30, queue: Queue.mainQueue(), alternate: .single(nil))
}

private nonisolated func telegramDestinationTitle(postbox: Postbox, chatID: Int64) -> Signal<String, NoError> {
    postbox.transaction { transaction in transaction.getPeer(PeerId(chatID)).map(telegramPeerTitle) ?? "Чат" }
}

nonisolated func telegramPrepareNativeEdit(account: Account, source: TelegramMessageActionSource,
    content: TelegramMessageEditContent) -> Signal<[MediaId: Media]?, NoError> {
    let ids = Set(content.formatted.entities.compactMap { entity -> Int64? in
        if case let .customEmoji(_, id) = entity.kind { return id }; return nil
    })
    guard ids.count <= 1024 else { return .single(nil) }
    let files = ids.isEmpty ? Signal<[Int64: TelegramMediaFile], NoError>.single([:])
        : TelegramEngine(account: account).stickers.resolveInlineStickers(fileIds: Array(ids))
    return (files |> take(1) |> mapToSignal { files in
        account.postbox.transaction { transaction in
            telegramNativeEditInlineStickers(transaction: transaction, accountID: account.peerId.toInt64(),
                source: source, content: content, files: files.filter { ids.contains($0.key) })
        }
    }) |> timeout(30, queue: Queue.mainQueue(), alternate: .single(nil))
}

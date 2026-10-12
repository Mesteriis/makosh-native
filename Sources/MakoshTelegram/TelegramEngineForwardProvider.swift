import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

struct TelegramForwardBatch {
    let messages: [EnqueueMessage]
    let previews: [TelegramComposerForwardPreview]
}

/// Called only on the native transaction queue; no UI-actor closure is captured.
nonisolated func telegramForwardBatch(transaction: Transaction, accountID: Int64, draft: TelegramComposerDraft) -> TelegramForwardBatch? {
    guard draft.isValid, draft.accountID == accountID, let intent = draft.forwardIntent, intent.isValid,
          let destination = transaction.getPeer(PeerId(draft.chatID)),
          destination is TelegramUser || destination is TelegramGroup || destination is TelegramChannel else { return nil }
    if let group = destination as? TelegramGroup {
        guard group.membership == .Member, !group.flags.contains(.deactivated),
              group.defaultBannedRights?.flags.contains(.banReadMessages) != true else { return nil }
    }
    if let channel = destination as? TelegramChannel {
        guard channel.participationStatus == .member,
              channel.bannedRights?.flags.contains(.banReadMessages) != true,
              channel.defaultBannedRights?.flags.contains(.banReadMessages) != true else { return nil }
    }
    func permitted(_ flag: TelegramChatBannedRightsFlags) -> Bool {
        if let group = destination as? TelegramGroup { return !group.hasBannedPermission(flag) }
        if let channel = destination as? TelegramChannel {
            if channel.flags.contains(.isCreator) || channel.adminRights != nil { return channel.hasPermission(.sendSomething) }
            if case .broadcast = channel.info { return false }
            return channel.bannedRights?.flags.contains(flag) != true && channel.defaultBannedRights?.flags.contains(flag) != true
        }
        return true
    }
    var messages: [EnqueueMessage] = [], previews: [TelegramComposerForwardPreview] = []
    let comment = draft.input.formattedText
    if !comment.text.isEmpty {
        guard telegramFormattedTextCanPrepare(comment, transaction: transaction), permitted(.banSendText) else { return nil }
        var reply: EngineMessageReplySubject?, thread = draft.threadID
        if let target = draft.replyTarget {
            guard target.isValid, let message = transaction.getMessage(MessageId(peerId: PeerId(target.peerID), namespace: target.namespace, id: target.messageID)) else { return nil }
            guard let source = TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message, limits: currentLimitsConfiguration(transaction: transaction)), accountID: accountID, chatID: draft.chatID)
                .quoting(target.quote, maximumLength: telegramReplyQuoteLimit(transaction: transaction)),
                  source.canReply, TelegramComposerReplyTarget(source: source) == target,
                  target.peerID == draft.chatID || source.metadata.migrationChatID == draft.chatID,
                  let prepared = telegramReplyEnqueueMessage(transaction: transaction, accountID: accountID, source: source, formatted: comment),
                  case let .message(_, _, _, _, replyThread, replySubject, _, _, _, _) = prepared else { return nil }
            if target.peerID != draft.chatID {
                guard let group = transaction.getPeer(PeerId(target.peerID)) as? TelegramGroup,
                      group.migrationReference?.peerId == PeerId(draft.chatID) else { return nil }
            }
            reply = replySubject; thread = draft.threadID ?? replyThread
        }
        messages.append(.message(text: comment.text, attributes: telegramOutgoingTextAttributes(comment), inlineStickers: [:], mediaReference: nil,
            threadId: thread, replyToMessageId: reply, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
    }
    for frozen in intent.sources {
        let id = MessageId(peerId: PeerId(frozen.peerID), namespace: frozen.namespace, id: frozen.messageID)
        guard let message = transaction.getMessage(id) else { return nil }
        let source = TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message, limits: currentLimitsConfiguration(transaction: transaction)), accountID: accountID, chatID: frozen.chatID)
        guard source.canForward, TelegramComposerForwardSource(source: source) == frozen else { return nil }
        if frozen.peerID != frozen.chatID {
            guard let group = transaction.getPeer(id.peerId) as? TelegramGroup,
                  group.migrationReference?.peerId == PeerId(frozen.chatID) else { return nil }
        }
        if message.attributes.contains(where: { $0 is InlineBotMessageAttribute }), !permitted(.banSendInline) { return nil }
        if message.media.isEmpty || message.media.allSatisfy({ $0 is TelegramMediaWebpage }) {
            guard permitted(.banSendText) else { return nil }
        }
        for media in message.media {
            let flag: TelegramChatBannedRightsFlags?
            if media is TelegramMediaImage { flag = .banSendPhotos }
            else if let file = media as? TelegramMediaFile {
                if file.isSticker || file.isAnimatedSticker { flag = .banSendStickers }
                else if file.isInstantVideo { flag = .banSendInstantVideos }
                else if file.isVoice { flag = .banSendVoice }
                else if file.isMusic { flag = .banSendMusic }
                else if file.isVideo { flag = .banSendVideos }
                else { flag = .banSendFiles }
            } else if let poll = media as? TelegramMediaPoll {
                if poll.publicity == .public, let channel = destination as? TelegramChannel,
                   case .broadcast = channel.info { return nil }
                flag = .banSendPolls
            }
            else if media is TelegramMediaContact || media is TelegramMediaMap || media is TelegramMediaWebpage { flag = .banSendText }
            else { return nil }
            if let flag, !permitted(flag) { return nil }
        }
        let options = ForwardOptionsMessageAttribute(hideNames: intent.hideNames || intent.hideCaptions, hideCaptions: intent.hideCaptions)
        messages.append(.forward(source: id, threadId: draft.threadID, grouping: intent.sources.count > 1 ? .auto : .none, attributes: [options], correlationId: nil))
        previews.append(.init(id: "\(frozen.peerID):\(frozen.namespace):\(frozen.messageID)", author: message.author.map(telegramPeerTitle) ?? "Сообщение",
            text: message.text, formattedText: source.metadata.formattedText, canCopy: source.canCopy,
            hasCaption: !message.text.isEmpty && message.media.contains { $0 is TelegramMediaImage || $0 is TelegramMediaFile },
            authorID: message.author?.id.toInt64()))
    }
    return TelegramForwardBatch(messages: messages, previews: previews)
}

nonisolated func telegramForwardAdmission(transaction: Transaction, accountID: Int64,
    draft: TelegramComposerDraft) -> Bool {
    guard draft.isValid, draft.accountID == accountID, draft.forwardDisposition == .submissionStarted,
          case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID,
              chatID: draft.chatID, threadID: draft.threadID), current == draft else { return false }
    return telegramForwardBatch(transaction: transaction, accountID: accountID, draft: draft) != nil
}

private nonisolated func forwardResolve(postbox: Postbox, accountID: Int64, draft: TelegramComposerDraft) -> Signal<[TelegramComposerForwardPreview]?, NoError> {
    postbox.transaction { telegramForwardBatch(transaction: $0, accountID: accountID, draft: draft)?.previews }
}
private enum ForwardAdmission { case rejected, uncertain, accepted(TelegramComposerDraft) }
enum TelegramForwardBegin { case started(TelegramComposerDraft), rejected, uncertain }
nonisolated func telegramForwardBegin(postbox: Postbox, accountID: Int64, draft: TelegramComposerDraft) -> Signal<TelegramForwardBegin, NoError> {
    postbox.transaction { transaction in
        guard case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID, threadID: draft.threadID),
              current == draft, draft.forwardDisposition == .prepared else { return .uncertain }
        guard telegramForwardBatch(transaction: transaction, accountID: accountID, draft: draft) != nil else { return .rejected }
        guard telegramForwardBeginSubmission(transaction: transaction, accountID: accountID, draft: draft),
              case let .success(stored) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID, threadID: draft.threadID), let stored else { return .uncertain }
        return .started(stored)
    }
}
private nonisolated func forwardEnqueue(account: Account, draft: TelegramComposerDraft,
    context: TelegramSendContext, consent: TelegramPaidSendConsent?) -> Signal<ForwardAdmission, NoError> {
    // Read once to construct the native batch, then validate the full frozen
    // batch again in admission after upstream asynchronous media transforms.
    account.postbox.transaction { telegramForwardBatch(transaction: $0, accountID: account.peerId.toInt64(), draft: draft) }
    |> mapToSignal { batch -> Signal<ForwardAdmission, NoError> in
        guard let batch else { return .single(.rejected) }
        let accepted = Atomic<TelegramComposerDraft?>(value: nil)
        return telegramEnqueueApprovedMessages(account: account, context: context, messages: batch.messages, consent: consent,
            specificAdmission: { transaction in
                telegramForwardAdmission(transaction: transaction, accountID: account.peerId.toInt64(), draft: draft)
            }, specificCommit: { transaction, ids in
                guard ids.count == batch.messages.count else { return }
                var values: [TelegramForwardQueueID] = [], unique = Set<MessageId>()
                for id in ids {
                    guard let id, id.peerId.toInt64() == draft.chatID, id.namespace == Namespaces.Message.Local,
                          unique.insert(id).inserted, let message = transaction.getMessage(id), !message.flags.contains(.Incoming) else { return }
                    values.append(.init(peerID: id.peerId.toInt64(), namespace: id.namespace, messageID: id.id))
                }
                guard telegramForwardRecordAcceptance(transaction: transaction, accountID: draft.accountID, draft: draft, ids: values),
                      case let .success(value) = telegramComposerDraftRead(transaction: transaction, accountID: draft.accountID, chatID: draft.chatID, threadID: draft.threadID) else { return }
                _ = accepted.swap(value)
            }) |> map { ids in
                if let result = accepted.with({ $0 }) { return .accepted(result) }
                return ids?.isEmpty == true ? .rejected : .uncertain
            }
    }
}

@MainActor final class TelegramEngineForwardProvider: TelegramComposerForwardProvider {
    private let account: Account
    private let approval: TelegramSendApprovalController
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account, approval: TelegramSendApprovalController) { self.account = account; self.approval = approval }
    func resolve(draft: TelegramComposerDraft, completion: @escaping @MainActor ([TelegramComposerForwardPreview]?) -> Void) -> any TelegramComposerForwardLease {
        let lease = ForwardLease()
        guard draft.accountID == accountID else { completion(nil); return lease }
        lease.observation.set((forwardResolve(postbox: account.postbox, accountID: accountID, draft: draft) |> deliverOnMainQueue).start(next: { value in MainActor.assumeIsolated { completion(value) } }))
        return lease
    }
    func submit(draft: TelegramComposerDraft, receive: @escaping @MainActor (TelegramComposerForwardEvent) -> Void) -> any TelegramComposerForwardLease {
        let lease = ForwardLease()
        guard draft.accountID == accountID else { receive(.uncertain); return lease }
        let context = TelegramSendContext(accountID: accountID, chatID: draft.chatID, threadID: draft.threadID,
            submissionRevision: draft.revision, messageCount: (draft.forwardIntent?.sources.count ?? 0) + (draft.text.isEmpty ? 0 : 1))
        receive(.awaitingApproval)
        lease.observation.set((telegramApprovalForDestination(account: account, approval: approval, context: context)
            |> deliverOnMainQueue).start(next: { result in
                MainActor.assumeIsolated {
                    guard !lease.stopped else { return }
                    guard case let .success(consent) = result else { receive(.rejected(draft)); return }
                    lease.continueAfterApproval(notify: { receive(.approvalCompleted) }, begin: {
                        self.submitApproved(draft: draft, context: context, consent: consent, lease: lease, receive: receive)
                    })
                }
            }))
        return lease
    }
    private func submitApproved(draft: TelegramComposerDraft, context: TelegramSendContext, consent: TelegramPaidSendConsent?,
        lease: ForwardLease, receive: @escaping @MainActor (TelegramComposerForwardEvent) -> Void) {
        let account = self.account
        // Standalone retains the bound account through enqueue/receipt/consume;
        // disposing the UI lease cannot turn a queued operation into a retry.
        let _ = (telegramForwardBegin(postbox: account.postbox, accountID: accountID, draft: draft)
            |> deliverOnMainQueue).startStandalone(next: { result in
                MainActor.assumeIsolated {
                    let started: TelegramComposerDraft
                    switch result {
                    case let .started(value): started = value
                    case .rejected: if !lease.stopped { receive(.rejected(draft)) }; return
                    case .uncertain: if !lease.stopped { receive(.uncertain) }; return
                    }
                    if !lease.stopped { receive(.committing(started)) }
                    let _ = (forwardEnqueue(account: account, draft: started, context: context, consent: consent) |> deliverOnMainQueue).startStandalone(next: { result in
                        MainActor.assumeIsolated {
                            switch result {
                            case .uncertain: if !lease.stopped { receive(.uncertain) }
                            case .rejected:
                                let _ = (telegramForwardResetRejected(postbox: account.postbox, accountID: draft.accountID, draft: started) |> deliverOnMainQueue).startStandalone(next: { result in
                                    MainActor.assumeIsolated { if !lease.stopped { if case let .success(value) = result { receive(.rejected(value)) } else { receive(.uncertain) } } }
                                })
                            case let .accepted(accepted):
                                if !lease.stopped { receive(.receiptAccepted(accepted)) }
                                let _ = (telegramForwardConsumeAccepted(postbox: account.postbox, accountID: draft.accountID, draft: accepted) |> deliverOnMainQueue).startStandalone(next: { result in
                                    MainActor.assumeIsolated { if !lease.stopped { if case let .success(value) = result { receive(.accepted(value)) } else { receive(.uncertain) } } }
                                })
                            }
                        }
                    })
                }
            })
    }
    func consumeAccepted(draft: TelegramComposerDraft, completion: @escaping @MainActor (TelegramComposerDraft?) -> Void) -> any TelegramComposerForwardLease {
        let lease = ForwardLease()
        guard draft.accountID == accountID else { completion(nil); return lease }
        let _ = (telegramForwardConsumeAccepted(postbox: account.postbox, accountID: accountID, draft: draft) |> deliverOnMainQueue).startStandalone(next: { result in
            MainActor.assumeIsolated { if !lease.stopped { completion(try? result.get()) } }
        })
        return lease
    }
}
@MainActor final class ForwardLease: TelegramComposerForwardLease {
    let observation = MetaDisposable()
    private(set) var stopped = false
    func continueAfterApproval(notify: () -> Void, begin: () -> Void) {
        guard !stopped else { return }
        notify()
        guard !stopped else { return }
        begin()
    }
    func cancel() { stopped = true; observation.dispose() }
    isolated deinit { cancel() }
}

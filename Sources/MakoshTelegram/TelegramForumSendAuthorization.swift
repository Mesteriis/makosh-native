import Postbox
import TelegramCore

/// Read-only admission for the current ordinary forum destination and topic.
/// The caller still supplies its authenticated Account ID and normal send guard.
nonisolated func telegramForumSendAuthorization(transaction: Transaction, accountID: Int64,
    chatID: Int64, threadID: Int64?, messages: [EnqueueMessage]) -> Bool {
    let account = PeerId(accountID), id = PeerId(chatID)
    guard account.namespace == Namespaces.Peer.CloudUser, account.id._internalGetInt64Value() > 0,
        id.id._internalGetInt64Value() > 0, !messages.isEmpty,
        let peer = transaction.getPeer(id) else { return false }
    guard let channel = peer as? TelegramChannel else {
        return threadID == nil && messages.allSatisfy { forumSendMessageThread($0) == nil }
    }
    guard !channel.flags.contains(.isMonoforum) else { return false }
    guard channel.flags.contains(.isForum) else {
        return threadID == nil && messages.allSatisfy { forumSendMessageThread($0) == nil }
    }
    guard channel.id.namespace == Namespaces.Peer.CloudChannel, case .group = channel.info,
        channel.participationStatus == .member,
        channel.bannedRights?.flags.contains(.banReadMessages) != true,
        channel.defaultBannedRights?.flags.contains(.banReadMessages) != true else { return false }
    let cache = transaction.getPeerCachedData(peerId: id) as? CachedChannelData
    guard cache?.isNotAccessible != true else { return false }
    let boosted: Bool
    if let required = cache?.boostsToUnrestrict, required > 0,
        let applied = cache?.appliedBoosts, applied >= required { boosted = true }
    else { boosted = false }
    for message in messages {
        let effectiveThread: Int64
        var media: [Media]
        switch message {
        case let .message(_, _, _, reference, nativeThread, reply, _, _, _, _):
            let replyThread: Int64?
            if let reply {
                guard reply.messageId.peerId == id, let source = transaction.getMessage(reply.messageId) else { return false }
                // Mirror the native queue's topic-opener fallback; a stale reply
                // cannot redirect an explicitly selected topic.
                replyThread = source.threadId ?? Int64(source.id.id)
            } else { replyThread = nil }
            if let selected = threadID {
                guard nativeThread == selected, replyThread.map({ $0 == selected }) ?? true else { return false }
                effectiveThread = selected
            } else {
                // All Messages never relies on native implicit General fallback.
                guard let replyThread, nativeThread.map({ $0 == replyThread }) ?? true else { return false }
                effectiveThread = replyThread
            }
            media = reference.map { [$0.media] } ?? []
        case let .forward(sourceID, nativeThread, _, _, _):
            guard let selected = threadID, nativeThread == selected,
                let source = transaction.getMessage(sourceID) else { return false }
            effectiveThread = selected
            media = source.media
        }
        guard let data = telegramForumSendTopic(transaction: transaction, chatID: chatID, threadID: effectiveThread),
            !data.isClosed || channel.adminRights != nil || channel.flags.contains(.isCreator) || data.isOwnedByMe,
            forumSendContentAllowed(channel: channel, media: media, boosted: boosted) else { return false }
    }
    return true
}

/// Presence/identity only; payment confirmation alone does not authorize send.
nonisolated func telegramForumSendTopic(transaction: Transaction, chatID: Int64,
    threadID: Int64) -> MessageHistoryThreadData? {
    let id = PeerId(chatID)
    guard id.namespace == Namespaces.Peer.CloudChannel, threadID > 0, threadID <= Int64(Int32.max),
        let channel = transaction.getPeer(id) as? TelegramChannel, channel.flags.contains(.isForum),
        !channel.flags.contains(.isMonoforum), case .group = channel.info else { return nil }
    guard let entry = transaction.getMessageHistoryThreadInfo(peerId: id, threadId: threadID)?.data else { return nil }
    return telegramForumTopicData(entry)
}

private nonisolated func forumSendMessageThread(_ message: EnqueueMessage) -> Int64? {
    switch message {
    case let .message(_, _, _, _, thread, _, _, _, _, _), let .forward(_, thread, _, _, _): return thread
    }
}

private nonisolated func forumSendContentAllowed(channel: TelegramChannel, media: [Media], boosted: Bool) -> Bool {
    if boosted { return true }
    if media.isEmpty { return channel.hasPermission(.sendText) }
    guard channel.hasPermission(.sendSomething) else { return false }
    for item in media {
        let ban: TelegramChatBannedRightsFlags?
        let mediaUmbrella: Bool
        switch item {
        case is TelegramMediaImage: ban = .banSendPhotos; mediaUmbrella = true
        case is TelegramMediaPoll: ban = .banSendPolls; mediaUmbrella = true
        case is TelegramMediaGame: ban = .banSendGames; mediaUmbrella = false
        case let file as TelegramMediaFile:
            if file.isAnimated && file.isVideo { ban = .banSendGifs; mediaUmbrella = true }
            else if file.isSticker { ban = .banSendStickers; mediaUmbrella = false }
            else if file.isMusic { ban = .banSendMusic; mediaUmbrella = true }
            else if file.isVoice { ban = .banSendVoice; mediaUmbrella = true }
            else if file.isInstantVideo { ban = .banSendInstantVideos; mediaUmbrella = true }
            else if file.isVideo { ban = .banSendVideos; mediaUmbrella = true }
            else { ban = .banSendFiles; mediaUmbrella = true }
        default: ban = nil; mediaUmbrella = false
        }
        if let ban, channel.hasBannedPermission(ban) != nil { return false }
        if mediaUmbrella, channel.hasBannedPermission(.banSendMedia) != nil { return false }
    }
    return true
}

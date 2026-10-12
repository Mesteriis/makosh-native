import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func forumSendUser(_ id: Int64 = 1) -> TelegramUser {
    TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id)),
        accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [],
        botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil)
}

private nonisolated func forumSendPeer(flags: TelegramChannelFlags = [.isForum],
    member: TelegramChannelParticipationStatus = .member, admin: TelegramChatAdminRightsFlags? = nil,
    banned: TelegramChatBannedRightsFlags = [], defaults: TelegramChatBannedRightsFlags = [],
    broadcast: Bool = false) -> TelegramChannel {
    TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(42)),
        accessHash: nil, title: "Synthetic forum", username: nil, photo: [], creationDate: 0, version: 1,
        participationStatus: member, info: broadcast ? .broadcast(.init(flags: [])) : .group(.init(flags: [])),
        flags: flags, restrictionInfo: nil, adminRights: admin.map { .init(rights: $0) },
        bannedRights: banned.isEmpty ? nil : .init(flags: banned, untilDate: Int32.max),
        defaultBannedRights: defaults.isEmpty ? nil : .init(flags: defaults, untilDate: Int32.max),
        usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
        profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil,
        subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
}

private nonisolated func forumSendData(closed: Bool = false, hidden: Bool = false,
    owned: Bool = false) -> MessageHistoryThreadData {
    .init(creationDate: 1, isOwnedByMe: owned, author: forumSendUser().id,
        info: .init(title: "Synthetic topic", icon: nil, iconColor: 0), incomingUnreadCount: 0,
        isMarkedUnread: false, maxIncomingReadId: 0, maxKnownMessageId: 10, maxOutgoingReadId: 0,
        isClosed: closed, isHidden: hidden, notificationSettings: .init(muteState: .unmuted,
            messageSound: .default, displayPreviews: .default, storySettings: .default), isMessageFeeRemoved: false)
}

private nonisolated func forumSendSeed(_ box: Postbox, peer: TelegramChannel = forumSendPeer(),
    cache: CachedChannelData = CachedChannelData(), topics: [(Int64, MessageHistoryThreadData)] = [(1, forumSendData()), (7, forumSendData())]) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([forumSendUser(), forumSendUser(2), peer], update: { _, next in next })
        transaction.updatePeerCachedData(peerIds: [peer.id], update: { _, _ in cache })
        for (id, data) in topics {
            // Native replay persists topic info only beside a top message index.
            _ = transaction.addMessages([StoreMessage(id: MessageId(peerId: peer.id,
                namespace: Namespaces.Message.Cloud, id: Int32(id) + 100), globallyUniqueId: nil,
                groupingKey: nil, threadId: id, timestamp: 50, flags: [.Incoming], tags: [],
                globalTags: [], localTags: [], forwardInfo: nil, authorId: forumSendUser(2).id,
                text: "Synthetic topic root", attributes: [], media: [])], location: .Random)
            transaction.setMessageHistoryThreadInfo(peerId: peer.id, threadId: id,
                info: StoredMessageHistoryThreadInfo(data: CodableEntry(data)!, summary: .init(
                    totalUnreadCount: data.incomingUnreadCount, isMarkedUnread: data.isMarkedUnread,
                    mutedUntil: nil, maxOutgoingReadId: data.maxOutgoingReadId)))
        }
        return true
    }
}

private nonisolated func forumSendPhoto() -> TelegramMediaImage {
    .init(imageId: .init(namespace: Namespaces.Media.LocalImage, id: 1), representations: [],
        immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
}

private nonisolated func forumSendMessage(thread: Int64? = 7, reply: MessageId? = nil,
    photo: Bool = false) -> EnqueueMessage {
    .message(text: "Synthetic forum message", attributes: [], inlineStickers: [:],
        mediaReference: photo ? .standalone(media: forumSendPhoto()) : nil, threadId: thread,
        replyToMessageId: reply.map { .init(messageId: $0, quote: nil, todoItemId: nil) },
        replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
}

private nonisolated func forumSendAllowed(_ box: Postbox, account: Int64 = 1,
    chat: PeerId = forumSendPeer().id, thread: Int64? = 7, messages: [EnqueueMessage]) -> Signal<Bool, NoError> {
    box.transaction { telegramForumSendAuthorization(transaction: $0, accountID: account,
        chatID: chat.toInt64(), threadID: thread, messages: messages) }
}

private nonisolated func forumSendSource(_ box: Postbox, chat: PeerId = forumSendPeer().id,
    id: Int32 = 70, thread: Int64? = 7, photo: Bool = false) -> Signal<MessageId, NoError> {
    box.transaction { transaction in
        let id = MessageId(peerId: chat, namespace: Namespaces.Message.Cloud, id: id)
        _ = transaction.addMessages([StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil,
            threadId: thread, timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [],
            forwardInfo: nil, authorId: forumSendUser(2).id, text: "Synthetic source", attributes: [],
            media: photo ? [forumSendPhoto()] : [])], location: .Random)
        return id
    }
}

private nonisolated func forumSendCorrupt(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.setMessageHistoryThreadInfo(peerId: forumSendPeer().id, threadId: 7,
            info: .init(data: CodableEntry(data: Data([0x7b])), summary: .init(totalUnreadCount: 0,
                isMarkedUnread: false, mutedUntil: nil, maxOutgoingReadId: 0)))
        return true
    }
}

private nonisolated func forumSendEnqueue(_ box: Postbox, thread: Int64,
    messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {
    enqueueMessagesLocally(postbox: box, accountPeerId: forumSendUser().id, isSupportUser: false,
        timestamp: 100, peerId: forumSendPeer().id, messages: messages, transactionAdmission: {
            telegramForumSendAuthorization(transaction: $0, accountID: 1,
                chatID: forumSendPeer().id.toInt64(), threadID: thread, messages: messages)
        })
}

private nonisolated func forumPaidContext(thread: Int64?) -> TelegramSendContext {
    .init(accountID: 1, chatID: forumSendPeer().id.toInt64(), threadID: thread,
        submissionRevision: UUID(), messageCount: 1)
}
private nonisolated func forumPaidMessage(thread: Int64?, reply: MessageId? = nil) -> EnqueueMessage {
    .message(text: "Synthetic paid topic", attributes: [PaidStarsMessageAttribute(stars: .init(value: 7, nanos: 0), postponeSending: false)],
        inlineStickers: [:], mediaReference: nil, threadId: thread,
        replyToMessageId: reply.map { .init(messageId: $0, quote: nil, todoItemId: nil) },
        replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
}
private nonisolated func forumPaidCreate(_ box: Postbox, context: TelegramSendContext,
    id: UUID) -> Signal<Result<TelegramPaidSendConsent, Error>, NoError> {
    box.transaction { transaction in Result { try telegramPaidSendConsentCreate(transaction: transaction,
        context: context, perMessageStars: 7, consentID: id) } }
}
private nonisolated func forumPaidRead(_ box: Postbox, context: TelegramSendContext,
    id: UUID) -> Signal<Result<TelegramPaidSendConsentRecord?, Error>, NoError> {
    box.transaction { transaction in Result { try telegramPaidSendConsentRead(transaction: transaction,
        context: context, consentID: id) } }
}
private nonisolated func forumPaidAllowed(_ box: Postbox, context: TelegramSendContext,
    id: UUID, message: EnqueueMessage) -> Signal<Bool, NoError> {
    box.transaction { telegramSendAuthorization(transaction: $0, context: context, messages: [message], consentID: id) }
}
private nonisolated func forumPaidEnqueue(_ box: Postbox, context: TelegramSendContext,
    id: UUID, message: EnqueueMessage) -> Signal<[MessageId?], NoError> {
    enqueueMessagesLocally(postbox: box, accountPeerId: forumSendUser().id, isSupportUser: false,
        timestamp: 100, peerId: forumSendPeer().id, messages: [message], transactionAdmission: { transaction in
            guard telegramSendAuthorization(transaction: transaction, context: context, messages: [message], consentID: id) else { return false }
            do { try telegramPaidSendConsentBegin(transaction: transaction, context: context, consentID: id); return true }
            catch { return false }
        }, transactionCommit: { transaction, ids in
            try? telegramPaidSendConsentConsume(transaction: transaction, context: context, consentID: id, messageIDs: ids)
        })
}

@MainActor final class TelegramForumSendAuthorizationTests: TelegramSourceFactsIntegrationTestCase {
    private func box() async throws -> Postbox {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return try await sourceFactsOpen(path)
    }

    // This boundary must preserve ordinary cloud conversations without a topic.
    func testOrdinaryCloudAllowsNilThreadButNeverInventsTopic() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSendSeed(box))
        let allowed = try await sourceFactsValue(forumSendAllowed(box, chat: forumSendUser(2).id,
            thread: nil, messages: [forumSendMessage(thread: nil)]))
        XCTAssertTrue(allowed)
        let topic = try await sourceFactsValue(forumSendAllowed(box, chat: forumSendUser(2).id,
            messages: [forumSendMessage()]))
        XCTAssertFalse(topic)
    }

    // Account/chat/topic and every native payload's destination must agree.
    func testSelectedThreadRequiresExactCurrentForumAndEveryMessageThread() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSendSeed(box))
        let allowed = try await sourceFactsValue(forumSendAllowed(box, messages: [forumSendMessage(), forumSendMessage()]))
        XCTAssertTrue(allowed)
        for messages in [[forumSendMessage(thread: nil)], [forumSendMessage(thread: 1)],
            [forumSendMessage(), forumSendMessage(thread: 1)], []] {
            let denied = try await sourceFactsValue(forumSendAllowed(box, messages: messages))
            XCTAssertFalse(denied)
        }
        let foreignAccount = try await sourceFactsValue(forumSendAllowed(box, account: forumSendPeer().id.toInt64(), messages: [forumSendMessage()]))
        XCTAssertFalse(foreignAccount)
    }

    // All Messages cannot silently enqueue to General; an actual reply binds it.
    func testAllMessagesRequiresExistingSameChatReplyAndKnownNativeThread() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSendSeed(box))
        let reply = try await sourceFactsValue(forumSendSource(box))
        for field: Int64? in [nil, 7] {
            let allowed = try await sourceFactsValue(forumSendAllowed(box, thread: nil,
                messages: [forumSendMessage(thread: field, reply: reply)]))
            XCTAssertTrue(allowed)
        }
        for message in [forumSendMessage(thread: nil), forumSendMessage(),
            forumSendMessage(thread: nil, reply: .init(peerId: forumSendUser(2).id, namespace: Namespaces.Message.Cloud, id: 70)),
            forumSendMessage(thread: nil, reply: .init(peerId: forumSendPeer().id, namespace: Namespaces.Message.Cloud, id: 99)),
            forumSendMessage(thread: 1, reply: reply)] {
            let denied = try await sourceFactsValue(forumSendAllowed(box, thread: nil, messages: [message]))
            XCTAssertFalse(denied)
        }
    }

    // A chosen topic never follows a stale or cross-topic reply into another topic.
    func testSelectedThreadRejectsCrossThreadReplyAndAllowsTopicOpener() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSendSeed(box))
        let other = try await sourceFactsValue(forumSendSource(box, thread: 1))
        let denied = try await sourceFactsValue(forumSendAllowed(box, messages: [forumSendMessage(reply: other)]))
        XCTAssertFalse(denied)
        let opener = try await sourceFactsValue(forumSendSource(box, id: 7, thread: nil))
        let allowed = try await sourceFactsValue(forumSendAllowed(box, messages: [forumSendMessage(reply: opener)]))
        XCTAssertTrue(allowed)
    }

    // Closed permissions match TelegramSwift: any admin, creator or topic owner.
    func testClosedTopicAllowsOnlyCurrentAdminCreatorOrOwner() async throws {
        let box = try await box()
        for (peer, owned, expected) in [(forumSendPeer(), false, false),
            (forumSendPeer(admin: [.canDeleteMessages]), false, true),
            (forumSendPeer(flags: [.isForum, .isCreator]), false, true),
            (forumSendPeer(), true, true)] {
            _ = try await sourceFactsValue(forumSendSeed(box, peer: peer,
                topics: [(7, forumSendData(closed: true, owned: owned))]))
            let result = try await sourceFactsValue(forumSendAllowed(box, messages: [forumSendMessage()]))
            XCTAssertEqual(result, expected)
        }
    }

    // Hidden General remains explicitly addressable; hidden is not a send ban.
    func testExplicitHiddenGeneralUsesFreshClosedStateWithoutFallback() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSendSeed(box, topics: [(1, forumSendData(hidden: true))]))
        let allowed = try await sourceFactsValue(forumSendAllowed(box, thread: 1, messages: [forumSendMessage(thread: 1)]))
        XCTAssertTrue(allowed)
        _ = try await sourceFactsValue(forumSendSeed(box, topics: [(1, forumSendData(closed: true, hidden: true))]))
        let closed = try await sourceFactsValue(forumSendAllowed(box, thread: 1, messages: [forumSendMessage(thread: 1)]))
        XCTAssertFalse(closed)
    }

    // Fresh peer conversions invalidate a remembered topic even with old data.
    func testConvertedOrdinaryMonoforumAndBroadcastRejectSelectedThread() async throws {
        let box = try await box()
        for peer in [forumSendPeer(flags: []), forumSendPeer(flags: [.isForum, .isMonoforum]),
            forumSendPeer(broadcast: true)] {
            _ = try await sourceFactsValue(forumSendSeed(box, peer: peer))
            let denied = try await sourceFactsValue(forumSendAllowed(box, messages: [forumSendMessage()]))
            XCTAssertFalse(denied)
        }
    }

    // Selected topics require a current member and readable native conversation.
    func testLeftKickedInaccessibleAndReadBannedCannotSend() async throws {
        let box = try await box()
        for (peer, cache) in [(forumSendPeer(member: .left), CachedChannelData()),
            (forumSendPeer(member: .kicked), CachedChannelData()),
            (forumSendPeer(banned: [.banReadMessages]), CachedChannelData()),
            (forumSendPeer(defaults: [.banReadMessages]), CachedChannelData()),
            (forumSendPeer(), CachedChannelData().withUpdatedIsNotAccessible(true))] {
            _ = try await sourceFactsValue(forumSendSeed(box, peer: peer, cache: cache))
            let denied = try await sourceFactsValue(forumSendAllowed(box, messages: [forumSendMessage()]))
            XCTAssertFalse(denied)
        }
    }

    // Native Int32 IDs cannot wrap; absent/corrupt thread info is not authority.
    func testInvalidUnknownAndCorruptTopicNeverAuthorize() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSendSeed(box))
        for thread in [Int64(0), -1, Int64(Int32.max) + 1, 8] {
            let denied = try await sourceFactsValue(forumSendAllowed(box, thread: thread, messages: [forumSendMessage(thread: thread)]))
            XCTAssertFalse(denied)
        }
        _ = try await sourceFactsValue(forumSendCorrupt(box))
        let corrupt = try await sourceFactsValue(forumSendAllowed(box, messages: [forumSendMessage()]))
        XCTAssertFalse(corrupt)
    }

    // Text permission uses the current personal/default native rights and boost.
    func testTextBansUseCurrentAdminAndExactBoostOverride() async throws {
        let box = try await box()
        let blocked = forumSendPeer(banned: [.banSendText])
        for (peer, cache, expected) in [(blocked, CachedChannelData(), false),
            (forumSendPeer(defaults: [.banSendText]), CachedChannelData(), false),
            (forumSendPeer(admin: [.canDeleteMessages], defaults: [.banSendText]), CachedChannelData(), true),
            (blocked, CachedChannelData().withUpdatedBoostsToUnrestrict(2).withUpdatedAppliedBoosts(1), false),
            (blocked, CachedChannelData().withUpdatedBoostsToUnrestrict(2).withUpdatedAppliedBoosts(2), true)] {
            _ = try await sourceFactsValue(forumSendSeed(box, peer: peer, cache: cache))
            let result = try await sourceFactsValue(forumSendAllowed(box, messages: [forumSendMessage()]))
            XCTAssertEqual(result, expected)
        }
    }

    // Forwarding must inspect actual source media, never trust empty attributes.
    func testPhotoAndForwardContentBansUseActualNativeMedia() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSendSeed(box))
        let source = try await sourceFactsValue(forumSendSource(box, photo: true))
        let forward = EnqueueMessage.forward(source: source, threadId: 7, grouping: .none, attributes: [], correlationId: nil)
        let allowed = try await sourceFactsValue(forumSendAllowed(box, messages: [forumSendMessage(photo: true), forward]))
        XCTAssertTrue(allowed)
        for ban: TelegramChatBannedRightsFlags in [.banSendPhotos, .banSendMedia] {
            _ = try await sourceFactsValue(forumSendSeed(box, peer: forumSendPeer(defaults: ban)))
            for message in [forumSendMessage(photo: true), forward] {
                let denied = try await sourceFactsValue(forumSendAllowed(box, messages: [message]))
                XCTAssertFalse(denied)
            }
        }
    }

    // The pure guard must execute with the insertion, not just when UI was opened.
    func testNativeQueueRechecksTopicClosedInInsertionTransaction() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSendSeed(box))
        let messages = [forumSendMessage()]
        let enqueue = forumSendEnqueue(box, thread: 7, messages: messages)
        let first = try await sourceFactsValue(enqueue)
        XCTAssertEqual(first.compactMap { $0 }.count, 1)
        _ = try await sourceFactsValue(forumSendSeed(box, topics: [(7, forumSendData(closed: true))]))
        let second = try await sourceFactsValue(enqueue)
        XCTAssertEqual(second, [])
    }

    // A selected paid topic is bound through approval and the actual native receipt.
    func testSelectedPaidTopicConsentMatchesQueuedThreadAndCannotMoveTopics() async throws {
        let box = try await box(), context = forumPaidContext(thread: 7), id = UUID()
        _ = try await sourceFactsValue(forumSendSeed(box, cache:
            CachedChannelData().withUpdatedSendPaidMessageStars(.init(value: 7, nanos: 0))))
        let created = try await sourceFactsValue(forumPaidCreate(box, context: context, id: id))
        guard case .success = created else { return XCTFail("Selected paid topic did not persist explicit approval") }
        let wrong = try await sourceFactsValue(forumPaidAllowed(box, context: context, id: id, message: forumPaidMessage(thread: 1)))
        XCTAssertFalse(wrong)
        let ids = try await sourceFactsValue(forumPaidEnqueue(box, context: context, id: id, message: forumPaidMessage(thread: 7)))
        XCTAssertEqual(ids.compactMap { $0 }.count, 1)
        let receipt = try await sourceFactsValue(forumPaidRead(box, context: context, id: id))
        guard case let .success(record?) = receipt, case let .accepted(accepted) = record.state else {
            return XCTFail("Selected topic native receipt was not accepted")
        }
        XCTAssertEqual(record.consent.context.threadID, 7)
        XCTAssertEqual(accepted.map(\.messageID), ids.compactMap { $0?.id })
    }

    // All Messages has no selected immutable paid topic, even with a valid reply.
    func testPaidAllMessagesCannotCreateApprovalOrUseNativeReplyInference() async throws {
        let box = try await box(), context = forumPaidContext(thread: nil), id = UUID()
        _ = try await sourceFactsValue(forumSendSeed(box, cache:
            CachedChannelData().withUpdatedSendPaidMessageStars(.init(value: 7, nanos: 0))))
        let reply = try await sourceFactsValue(forumSendSource(box))
        let create = try await sourceFactsValue(forumPaidCreate(box, context: context, id: id))
        if case .success = create { XCTFail("Unselected paid topic created approval") }
        let allowed = try await sourceFactsValue(forumPaidAllowed(box, context: context, id: id, message: forumPaidMessage(thread: nil, reply: reply)))
        XCTAssertFalse(allowed)
    }
}

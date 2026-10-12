import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func topicForwardUser(_ number: Int64) -> TelegramUser {
    TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(number)),
        accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [],
        botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func topicForwardPeer() -> TelegramChannel {
    TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(43)),
        accessHash: nil, title: "Synthetic forum", username: nil, photo: [], creationDate: 0, version: 1,
        participationStatus: .member, info: .group(.init(flags: [])), flags: [.isForum], restrictionInfo: nil,
        adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil,
        sendPaidMessageStars: nil, linkedMonoforumId: nil)
}
private nonisolated func topicForwardPhoto() -> TelegramMediaImage {
    .init(imageId: .init(namespace: Namespaces.Media.LocalImage, id: 500), representations: [],
        immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
}
private nonisolated func topicForwardSeed(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let forum = topicForwardPeer(), user = topicForwardUser(7)
        transaction.updatePeersInternal([topicForwardUser(1), user, forum], update: { _, next in next })
        transaction.updatePeerCachedData(peerIds: [forum.id], update: { _, _ in CachedChannelData() })
        for number: Int32 in [1, 2] {
            _ = transaction.addMessages([StoreMessage(id: .init(peerId: user.id, namespace: Namespaces.Message.Cloud, id: number),
                globallyUniqueId: nil, groupingKey: 90, threadId: nil, timestamp: 50, flags: [.Incoming],
                tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: user.id,
                text: "Forward source \(number)", attributes: [], media: [])], location: .Random)
        }
        for thread: Int64 in [7, 9] {
            _ = transaction.addMessages([StoreMessage(id: .init(peerId: forum.id, namespace: Namespaces.Message.Cloud, id: Int32(thread) + 100),
                globallyUniqueId: nil, groupingKey: nil, threadId: thread, timestamp: 100, flags: [.Incoming],
                tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: user.id,
                text: "prefix 😀 quoted tail", attributes: [TextEntitiesMessageAttribute(entities: [.init(range: 10..<16, type: .Bold)])],
                media: [topicForwardPhoto()])], location: .Random)
            let data = MessageHistoryThreadData(creationDate: 1, isOwnedByMe: false, author: user.id,
                info: .init(title: "Synthetic topic", icon: nil, iconColor: 0), incomingUnreadCount: 0,
                isMarkedUnread: false, maxIncomingReadId: 0, maxKnownMessageId: 109, maxOutgoingReadId: 0,
                isClosed: false, isHidden: false, notificationSettings: .init(muteState: .unmuted,
                    messageSound: .default, displayPreviews: .default, storySettings: .default), isMessageFeeRemoved: false)
            transaction.setMessageHistoryThreadInfo(peerId: forum.id, threadId: thread,
                info: .init(data: CodableEntry(data)!, summary: .init(totalUnreadCount: 0,
                    isMarkedUnread: false, mutedUntil: nil, maxOutgoingReadId: 0)))
        }
        return true
    }
}
private nonisolated func topicForwardDraft(_ box: Postbox, comment: Bool = false,
    quote: Bool = false) -> Signal<TelegramComposerDraft?, NoError> {
    box.transaction { transaction in
        let sources = [Int32(1), 2].compactMap { id -> TelegramComposerForwardSource? in
            transaction.getMessage(.init(peerId: topicForwardUser(7).id, namespace: Namespaces.Message.Cloud, id: id))
                .map { .init(source: telegramMessageActionSource($0, accountID: 1, chatID: 7)) }
        }
        guard sources.count == 2 else { return nil }
        var target: TelegramComposerReplyTarget?
        if quote {
            guard let message = transaction.getMessage(.init(peerId: topicForwardPeer().id, namespace: Namespaces.Message.Cloud, id: 107)) else { return nil }
            let source = telegramMessageActionSource(message, accountID: 1, chatID: topicForwardPeer().id.toInt64())
            guard let formatted = source.metadata.formattedText,
                  let selection = TelegramReplyQuote(source: formatted,
                selection: .init(location: 7, length: 9)), let quoted = source.quoting(selection) else { return nil }
            target = .init(source: quoted)
        }
        return TelegramComposerDraft(accountID: 1, chatID: topicForwardPeer().id.toInt64(),
            text: comment ? "Synthetic comment" : "", threadID: 7, replyTarget: target,
            forwardIntent: .init(sources: sources, hideNames: true))
    }
}
private nonisolated func topicForwardSave(_ box: Postbox, draft: TelegramComposerDraft,
    copies: Bool = false) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        guard telegramComposerDraftWriteLocal(transaction: transaction, draft: draft) else { return false }
        if copies {
            // Equal revision/intent deliberately proves that identity includes
            // the topic key rather than relying on usually-unique UUIDs.
            let nilScope = TelegramComposerDraft(accountID: draft.accountID, chatID: draft.chatID,
                text: "Ordinary composer must survive", revision: draft.revision, forwardIntent: draft.forwardIntent)
            let other = TelegramComposerDraft(accountID: draft.accountID, chatID: draft.chatID,
                text: "Other topic must survive", revision: draft.revision, threadID: 9, forwardIntent: draft.forwardIntent)
            return telegramComposerDraftWriteLocal(transaction: transaction, draft: nilScope)
                && telegramComposerDraftWriteLocal(transaction: transaction, draft: other)
        }
        return true
    }
}
private struct TopicForwardMediaID: Equatable, Sendable {
    let namespace: Int32
    let id: Int64
}
private struct TopicForwardBatchSummary: Sendable {
    let threads: [Int64?]
    let quoteText: String?
    let quoteOffset: Int?
    let quoteEntities: [TelegramTextEntity]?
    let quoteMediaID: TopicForwardMediaID?
}
private nonisolated func topicForwardBatchSummary(_ box: Postbox, draft: TelegramComposerDraft) -> Signal<TopicForwardBatchSummary?, NoError> {
    box.transaction { transaction in
        guard let batch = telegramForwardBatch(transaction: transaction, accountID: 1, draft: draft) else { return nil }
        var threads: [Int64?] = [], quote: EngineMessageReplyQuote?
        for item in batch.messages {
            switch item {
            case let .message(_, _, _, _, thread, reply, _, _, _, _): threads.append(thread); quote = reply?.quote
            case let .forward(_, thread, _, _, _): threads.append(thread)
            }
        }
        return .init(threads: threads, quoteText: quote?.text, quoteOffset: quote?.offset,
            quoteEntities: quote.flatMap { try? telegramFormattedText(text: $0.text, entities: $0.entities).entities },
            quoteMediaID: (quote?.media?.id).map { .init(namespace: $0.namespace, id: $0.id) })
    }
}
private struct TopicForwardState: Sendable {
    let draft: TelegramComposerDraft?
    let bytes: [Data?]
    let saved: TelegramSavedMessagesForwardRecord?
}
private nonisolated func topicForwardState(_ box: Postbox, draft: TelegramComposerDraft) -> Signal<TopicForwardState, NoError> {
    box.transaction { transaction in
        let current = try? telegramComposerDraftRead(transaction: transaction, accountID: 1,
            chatID: draft.chatID, threadID: 7).get()
        let bytes = [nil, Int64(7), 9].map { thread in transaction.getPreferencesEntry(
            key: telegramComposerDraftKey(accountID: 1, chatID: draft.chatID, threadID: thread))?.data }
        let saved = try? telegramSavedForwardRead(transaction: transaction, accountID: 1).get()
        return .init(draft: current, bytes: bytes, saved: saved)
    }
}
private nonisolated func topicForwardStarted(_ box: Postbox, draft: TelegramComposerDraft) -> Signal<TelegramComposerDraft?, NoError> {
    box.transaction { transaction in
        guard telegramForwardBeginSubmission(transaction: transaction, accountID: 1, draft: draft) else { return nil }
        return try? telegramComposerDraftRead(transaction: transaction, accountID: 1, chatID: draft.chatID, threadID: draft.threadID).get()
    }
}
private nonisolated func topicForwardAdmission(_ box: Postbox, draft: TelegramComposerDraft) -> Signal<Bool, NoError> {
    box.transaction { telegramForwardAdmission(transaction: $0, accountID: 1, draft: draft) }
}
private nonisolated func topicForwardChanged(_ box: Postbox, draft: TelegramComposerDraft) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        telegramComposerDraftWriteLocal(transaction: transaction,
            draft: .init(accountID: 1, chatID: draft.chatID, text: "Later scoped input", threadID: 7,
                forwardIntent: draft.forwardIntent, forwardDisposition: .submissionStarted))
    }
}
private nonisolated func topicSavedRequest(_ draft: TelegramComposerDraft) -> TelegramSavedMessagesForwardRequest {
    .init(contextID: UUID(), accountID: 1, sources: draft.forwardIntent!.sources,
        origin: .init(chatID: draft.chatID, threadID: 7, revision: draft.revision, intentID: draft.forwardIntent!.id))
}
private nonisolated func topicSavedBegin(_ box: Postbox, request: TelegramSavedMessagesForwardRequest) -> Signal<Bool, NoError> {
    box.transaction { telegramSavedForwardBegin(transaction: $0, accountID: 1, request: request) }
}
private nonisolated func topicSavedQueue(_ box: Postbox, request: TelegramSavedMessagesForwardRequest) -> Signal<[MessageId?], NoError> {
    box.transaction { telegramForwardBatch(transaction: $0, accountID: 1, draft: request.draft) }
    |> mapToSignal { batch in
        guard let batch else { return .single([]) }
        return enqueueMessagesLocally(postbox: box, accountPeerId: topicForwardUser(1).id,
            isSupportUser: false, timestamp: 100, peerId: topicForwardUser(1).id, messages: batch.messages,
            transactionAdmission: { telegramSavedForwardAdmission(transaction: $0, accountID: 1, request: request) },
            transactionCommit: { transaction, ids in
                let values = ids.compactMap { $0 }.map { TelegramForwardQueueID(peerID: $0.peerId.toInt64(), namespace: $0.namespace, messageID: $0.id) }
                _ = telegramSavedForwardRecordAcceptance(transaction: transaction, accountID: 1, request: request, ids: values)
            })
    }
}
private nonisolated func topicForwardCorrupt(_ box: Postbox, draft: TelegramComposerDraft) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.setPreferencesEntry(key: telegramComposerDraftKey(accountID: 1, chatID: draft.chatID, threadID: 7),
            value: .init(data: Data("Unknown future topic composer".utf8)))
        return true
    }
}

@MainActor final class TelegramForumForwardTests: TelegramSourceFactsIntegrationTestCase {
    private func box() async throws -> Postbox {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        let box = try await sourceFactsOpen(path)
        _ = try await sourceFactsValue(topicForwardSeed(box)); return box
    }
    private func draft(_ box: Postbox, comment: Bool = false, quote: Bool = false) async throws -> TelegramComposerDraft {
        let value = try await sourceFactsValue(topicForwardDraft(box, comment: comment, quote: quote))
        return try XCTUnwrap(value)
    }
    private func expect(_ signal: Signal<Bool, NoError>, expected: Bool = true,
        file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await sourceFactsValue(signal)
        XCTAssertEqual(value, expected, file: file, line: line)
    }
    func testSelectedTopicBatchKeepsThreadOnCommentAndEveryForward() async throws {
        let box = try await box(), draft = try await draft(box, comment: true)
        guard let result = try await sourceFactsValue(topicForwardBatchSummary(box, draft: draft)) else { return XCTFail("Valid native forward batch missing") }
        XCTAssertEqual(result.threads, [7, 7, 7])
    }
    func testForwardCommentPreservesSelectedQuoteAndFreshNativeMedia() async throws {
        let box = try await box(), draft = try await draft(box, comment: true, quote: true)
        guard let result = try await sourceFactsValue(topicForwardBatchSummary(box, draft: draft)) else { return XCTFail("Quoted forward comment was rejected") }
        XCTAssertEqual(result.threads, [7, 7, 7]); XCTAssertEqual(result.quoteText, "😀 quoted")
        XCTAssertEqual(result.quoteOffset, 7)
        XCTAssertEqual(result.quoteEntities, [.init(offset: 3, length: 6, kind: .bold)])
        XCTAssertEqual(result.quoteMediaID, .init(namespace: Namespaces.Media.LocalImage, id: 500))
    }
    func testNativeForwardBeginUsesSelectedScopeDespiteEqualUnscopedRevision() async throws {
        let box = try await box(), draft = try await draft(box)
        try await expect(topicForwardSave(box, draft: draft, copies: true))
        let before = try await sourceFactsValue(topicForwardState(box, draft: draft))
        let result = try await sourceFactsValue(telegramForwardBegin(postbox: box, accountID: 1, draft: draft))
        guard case let .started(started) = result else { return XCTFail("Selected persisted forward must begin in its own scope") }
        XCTAssertEqual(started.threadID, 7); XCTAssertEqual(started.forwardDisposition, .submissionStarted)
        let after = try await sourceFactsValue(topicForwardState(box, draft: draft))
        XCTAssertEqual(after.draft, started); XCTAssertEqual(after.bytes[0], before.bytes[0]); XCTAssertEqual(after.bytes[2], before.bytes[2])
    }
    func testNativeForwardAdmissionRechecksExactScopedStartedDraft() async throws {
        let box = try await box(), draft = try await draft(box)
        try await expect(topicForwardSave(box, draft: draft, copies: true))
        let startedValue = try await sourceFactsValue(topicForwardStarted(box, draft: draft))
        let started = try XCTUnwrap(startedValue)
        try await expect(topicForwardAdmission(box, draft: started))
        try await expect(topicForwardChanged(box, draft: started))
        try await expect(topicForwardAdmission(box, draft: started), expected: false)
    }
    func testSavedTopicOriginReceiptClearsOnlyExactScopeAndKeepsInputReplyQuote() async throws {
        let box = try await box(), draft = try await draft(box, comment: true, quote: true)
        try await expect(topicForwardSave(box, draft: draft, copies: true))
        let before = try await sourceFactsValue(topicForwardState(box, draft: draft)), request = topicSavedRequest(draft)
        try await expect(topicSavedBegin(box, request: request))
        let savedBatch = try await sourceFactsValue(topicForwardBatchSummary(box, draft: request.draft))
        XCTAssertEqual(savedBatch?.threads, [nil, nil], "Origin topic is never a destination topic in Saved Messages")
        let ids = try await sourceFactsValue(topicSavedQueue(box, request: request))
        XCTAssertEqual(ids.compactMap { $0 }.count, 2)
        let after = try await sourceFactsValue(topicForwardState(box, draft: draft))
        XCTAssertEqual(after.saved?.schemaVersion, 2); XCTAssertEqual(after.saved?.acceptedIDs?.count, 2)
        XCTAssertNil(after.draft?.forwardIntent); XCTAssertEqual(after.draft?.threadID, 7)
        XCTAssertEqual(after.draft?.input, draft.input); XCTAssertEqual(after.draft?.replyTarget, draft.replyTarget)
        XCTAssertNotEqual(after.draft?.revision, draft.revision)
        XCTAssertEqual(after.bytes[0], before.bytes[0]); XCTAssertEqual(after.bytes[2], before.bytes[2])
    }
    func testUnknownTopicOriginCannotConsumeMatchingOrdinaryComposerOrQueue() async throws {
        let box = try await box(), draft = try await draft(box)
        try await expect(topicForwardSave(box, draft: draft, copies: true))
        let request = topicSavedRequest(draft)
        try await expect(topicSavedBegin(box, request: request))
        try await expect(topicForwardCorrupt(box, draft: draft))
        let before = try await sourceFactsValue(topicForwardState(box, draft: draft))
        let ids = try await sourceFactsValue(topicSavedQueue(box, request: request))
        XCTAssertTrue(ids.isEmpty)
        let after = try await sourceFactsValue(topicForwardState(box, draft: draft))
        XCTAssertNil(after.saved?.acceptedIDs); XCTAssertEqual(after.bytes, before.bytes)
    }
    func testOriginWirePreservesLegacyNilAndRejectsUnscopedOrMalformedTopicClaims() async throws {
        let box = try await box(), draft = try await draft(box)
        let topic = topicSavedRequest(draft)
        let legacy = TelegramSavedMessagesForwardRequest(contextID: UUID(), accountID: 1, sources: topic.sources,
            origin: .init(chatID: draft.chatID, revision: draft.revision, intentID: draft.forwardIntent!.id))
        let decoded = try JSONDecoder().decode(TelegramSavedMessagesForwardRecord.self,
            from: JSONEncoder().encode(TelegramSavedMessagesForwardRecord(request: legacy)))
        XCTAssertEqual(decoded.schemaVersion, 1); XCTAssertNil(decoded.request.origin?.threadID); XCTAssertTrue(decoded.isValid)
        let current = TelegramSavedMessagesForwardRecord(request: topic)
        XCTAssertEqual(current.schemaVersion, 2); XCTAssertTrue(current.isValid)
        var downgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        downgraded["schemaVersion"] = 1
        let wrongVersion = try JSONDecoder().decode(TelegramSavedMessagesForwardRecord.self,
            from: JSONSerialization.data(withJSONObject: downgraded))
        XCTAssertFalse(wrongVersion.isValid)
        for (chat, thread) in [(draft.chatID, Int64(0)), (draft.chatID, -1), (draft.chatID, Int64(Int32.max) + 1), (Int64(42), 7)] {
            let request = TelegramSavedMessagesForwardRequest(contextID: UUID(), accountID: 1, sources: topic.sources,
                origin: .init(chatID: chat, threadID: thread, revision: draft.revision, intentID: draft.forwardIntent!.id))
            XCTAssertFalse(request.isValid)
        }
    }
}

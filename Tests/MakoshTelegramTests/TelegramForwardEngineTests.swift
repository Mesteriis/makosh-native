import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func forwardUser(_ id: PeerId) -> TelegramUser {
    TelegramUser(id: id, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private func forwardSeed(_ box: Postbox, protected: Bool = false, text: String = "source", media: [Media] = []) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let source = PeerId(7), destination = PeerId(42)
        transaction.updatePeersInternal([forwardUser(source), forwardUser(destination)], update: { _, new in new })
        for number: Int32 in [1, 2] {
            let id = MessageId(peerId: source, namespace: Namespaces.Message.Cloud, id: number)
            let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: 99, threadId: nil,
                timestamp: 100, flags: protected ? [.CopyProtected] : [], tags: [], globalTags: [], localTags: [],
                forwardInfo: nil, authorId: source, text: text, attributes: [], media: media)
            if transaction.getMessage(id) != nil { transaction.updateMessage(id) { _ in .update(message) } }
            else { _ = transaction.addMessages([message], location: .Random) }
        }
    }
}
private func forwardSources(_ box: Postbox) -> Signal<[TelegramComposerForwardSource], NoError> {
    box.transaction { transaction in
        [Int32(1), 2].compactMap { number in
            transaction.getMessage(MessageId(peerId: PeerId(7), namespace: Namespaces.Message.Cloud, id: number)).map {
                TelegramComposerForwardSource(source: telegramMessageActionSource($0, accountID: 1, chatID: 7))
            }
        }
    }
}
private func forwardDestination(_ box: Postbox, channel: Bool, status: Int = 0,
                                deactivated: Bool = false, banned: TelegramChatBannedRightsFlags = [],
                                creator: Bool = false, broadcast: Bool = false, admin: Bool = false, canPost: Bool = true) -> Signal<Int64, NoError> {
    box.transaction { transaction in
        let id = PeerId(namespace: channel ? Namespaces.Peer.CloudChannel : Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(42))
        let rights = TelegramChatBannedRights(flags: banned, untilDate: Int32.max)
        let peer: Peer
        if channel {
            peer = TelegramChannel(id: id, accessHash: nil, title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
                participationStatus: status == 1 ? .left : status == 2 ? .kicked : .member,
                info: broadcast ? .broadcast(TelegramChannelBroadcastInfo(flags: [])) : .group(TelegramChannelGroupInfo(flags: [])),
                flags: creator ? [.isCreator] : [], restrictionInfo: nil, adminRights: admin ? TelegramChatAdminRights(rights: canPost ? [.canPostMessages] : [.canDeleteMessages]) : nil,
                bannedRights: banned.contains(.banReadMessages) ? rights : nil, defaultBannedRights: rights,
                usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
                profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil,
                verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
        } else {
            peer = TelegramGroup(id: id, title: "Synthetic", photo: [], participantCount: 2,
                role: creator ? .creator(rank: nil) : admin ? .admin(TelegramChatAdminRights(rights: [.canDeleteMessages]), rank: nil) : .member, membership: status == 1 ? .Left : status == 2 ? .Removed : .Member,
                flags: deactivated ? [.deactivated] : [], defaultBannedRights: rights, migrationReference: nil, creationDate: 0, version: 1)
        }
        transaction.updatePeersInternal([peer], update: { _, new in new })
        return id.toInt64()
    }
}
private func forwardPhoto() -> TelegramMediaImage {
    TelegramMediaImage(imageId: MediaId(namespace: 0, id: 9), representations: [], immediateThumbnailData: nil,
        reference: nil, partialReference: nil, flags: [])
}
private func forwardPoll(publicity: TelegramMediaPollPublicity) -> TelegramMediaPoll {
    TelegramMediaPoll(pollId: MediaId(namespace: 0, id: 10), publicity: publicity, kind: .poll(multipleAnswers: false),
        text: "Synthetic poll", textEntities: [], options: [], correctAnswers: nil,
        results: TelegramMediaPollResults(voters: nil, totalVoters: nil, recentVoters: [], solution: nil),
        isClosed: false, deadlineTimeout: nil)
}
private struct ForwardSummary: Sendable {
    let count: Int
    let text: String?
    let entities: Bool
    let reply: Bool
    let grouped: Bool
    let options: Bool
}
private func forwardSummary(_ box: Postbox, draft: TelegramComposerDraft) -> Signal<ForwardSummary?, NoError> {
    box.transaction { transaction in
        guard let batch = telegramForwardBatch(transaction: transaction, accountID: 1, draft: draft) else { return nil }
        var text: String?, entities = false, reply = false, grouped = true, options = true
        for message in batch.messages {
            switch message {
            case let .message(value, attributes, _, _, _, target, _, _, _, _):
                text = value; entities = attributes.contains { $0 is TextEntitiesMessageAttribute }; reply = target != nil
            case let .forward(_, thread, grouping, attributes, _):
                if case .none = grouping { grouped = false }
                let attribute = attributes.compactMap { $0 as? ForwardOptionsMessageAttribute }.first
                options = options && attribute?.hideNames == true && attribute?.hideCaptions == true && thread == nil
            }
        }
        return ForwardSummary(count: batch.messages.count, text: text, entities: entities, reply: reply, grouped: grouped, options: options)
    }
}

private func forwardPreviewAuthors(_ box: Postbox, draft: TelegramComposerDraft) -> Signal<[Int64?]?, NoError> {
    box.transaction { transaction in
        telegramForwardBatch(transaction: transaction, accountID: 1, draft: draft)?.previews.map(\.authorID)
    }
}

private nonisolated func forwardPaidSourceSeed(_ box: Postbox) -> Signal<Void, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([forwardUser(PeerId(1)), forwardUser(PeerId(7)), forwardUser(PeerId(42))],
            update: { _, next in next })
        transaction.updatePeerCachedData(peerIds: [PeerId(42)], update: { _, _ in
            CachedUserData().withUpdatedSendPaidMessageStars(.init(value: 3, nanos: 0))
        })
        _ = transaction.addMessages([StoreMessage(id: .init(peerId: PeerId(7), namespace: Namespaces.Message.Cloud, id: 1),
            globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 100, flags: [.Incoming],
            tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: PeerId(7), text: "Previously paid source",
            attributes: [PaidStarsMessageAttribute(stars: .init(value: 17, nanos: 0), postponeSending: false)], media: [])], location: .Random)
    }
}
private nonisolated func forwardPaidSourceQueue(_ box: Postbox, destination: Int64, price: Int64?) -> Signal<[MessageId?], NoError> {
    box.transaction { transaction -> TelegramNativeSendPreparation? in
        let context = TelegramSendContext(accountID: 1, chatID: destination, threadID: nil,
            submissionRevision: UUID(), messageCount: 1)
        let consent = price.map { TelegramPaidSendConsent(id: UUID(), context: context, perMessageStars: $0, totalStars: $0) }
        let message = EnqueueMessage.forward(source: .init(peerId: PeerId(7), namespace: Namespaces.Message.Cloud, id: 1),
            threadId: nil, grouping: .none,
            attributes: [ForwardOptionsMessageAttribute(hideNames: true, hideCaptions: false)], correlationId: nil)
        return telegramNativeSendPreparation(transaction: transaction, context: context, messages: [message], files: [:], consent: consent)
    } |> mapToSignal { prepared in
        guard let prepared else { return .single([]) }
        // Isolate the native transformation of an already prepared payload.
        // Durable consent/admission authority is covered by the journal tests.
        return enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false,
            timestamp: 101, peerId: PeerId(destination), messages: prepared.messages)
    }
}
private struct ForwardPaidSourceSummary: Sendable {
    let fees: [Int64]
    let originalFees: [Int64]
    let hideNames: Bool
}
private nonisolated func forwardPaidSourceSummary(_ box: Postbox, id: MessageId) -> Signal<ForwardPaidSourceSummary?, NoError> {
    box.transaction { transaction in
        guard let queued = transaction.getMessage(id),
              let original = transaction.getMessage(.init(peerId: PeerId(7), namespace: Namespaces.Message.Cloud, id: 1)) else { return nil }
        return .init(fees: queued.attributes.compactMap { ($0 as? PaidStarsMessageAttribute)?.stars.value },
            originalFees: original.attributes.compactMap { ($0 as? PaidStarsMessageAttribute)?.stars.value },
            hideNames: queued.attributes.compactMap { $0 as? ForwardOptionsMessageAttribute }.first?.hideNames == true)
    }
}

@MainActor final class TelegramForwardEngineTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Synthetic forward transaction")
        var result: T?
        let lease = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { lease.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func open() async throws -> Postbox {
        initializeAccountManagement()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-forward-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 17, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 18, count: 16)))
        let ready = expectation(description: "Encrypted Postbox")
        var result: Postbox?
        let lease = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false, isReadOnly: false,
            useCopy: false, useCaches: false, removeDatabaseOnError: false) |> deliverOnMainQueue).start(next: {
                if case let .postbox(box) = $0 { result = box; ready.fulfill() }
            })
        defer { lease.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        let box = try XCTUnwrap(result), stores = expectation(description: "Both MediaBox stores")
        stores.expectedFulfillmentCount = 2
        let a = (box.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        let b = (box.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        defer { a.dispose(); b.dispose() }
        await fulfillment(of: [stores], timeout: 20)
        return box
    }
    func testNativePreviewRetainsAuthorIdentityForOptionCounts() async throws {
        let box = try await open(); let _: Void = try await value(forwardSeed(box))
        let sources = try await value(forwardSources(box))
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "", forwardIntent: .init(sources: sources))
        let authors = try await value(forwardPreviewAuthors(box, draft: draft))
        XCTAssertEqual(authors, [7, 7])
    }
    func testNativeBatchRetainsRichCommentReplyAndForwardOptions() async throws {
        let box = try await open(); let _: Void = try await value(forwardSeed(box))
        let sources = try await value(forwardSources(box)); XCTAssertEqual(sources.count, 2)
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "comment", entities: [.init(offset: 0, length: 7, kind: .bold)]))
        // Reply refers to a message in the source chat, so destination must match
        // that chat; forwarding to it is valid and keeps replies on comment only.
        let draft = TelegramComposerDraft(accountID: 1, chatID: 7, input: input,
            replyTarget: .init(peerID: 7, namespace: Namespaces.Message.Cloud, messageID: 1),
            forwardIntent: .init(sources: sources, hideNames: false, hideCaptions: true))
        let value = try await value(forwardSummary(box, draft: draft))
        let summary = try XCTUnwrap(value)
        XCTAssertEqual(summary.count, 3); XCTAssertEqual(summary.text, "comment")
        XCTAssertTrue(summary.entities); XCTAssertTrue(summary.reply); XCTAssertTrue(summary.grouped); XCTAssertTrue(summary.options)
    }
    func testMissingChangedProtectedSourceAndForeignAccountFailClosed() async throws {
        let box = try await open(); let _: Void = try await value(forwardSeed(box))
        let sources = try await value(forwardSources(box)), draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "", forwardIntent: .init(sources: sources))
        let valid = try await value(forwardSummary(box, draft: draft)); XCTAssertNotNil(valid)
        let foreign = TelegramComposerDraft(accountID: 2, chatID: 42, text: "", forwardIntent: draft.forwardIntent)
        let foreignResult = try await value(forwardSummary(box, draft: foreign)); XCTAssertNil(foreignResult)
        let missing = TelegramComposerForwardSource(chatID: 7, peerID: 7, namespace: 0, messageID: 999, fingerprint: sources[0].fingerprint)
        let absent = TelegramComposerDraft(accountID: 1, chatID: 42, text: "comment", forwardIntent: .init(sources: [missing]))
        let absentResult = try await value(forwardSummary(box, draft: absent)); XCTAssertNil(absentResult, "No comment-only fallback")
        let _: Void = try await value(forwardSeed(box, text: "changed"))
        let changedResult = try await value(forwardSummary(box, draft: draft)); XCTAssertNil(changedResult)
        let _: Void = try await value(forwardSeed(box, protected: true))
        let protectedSources = try await value(forwardSources(box))
        let protected = TelegramComposerDraft(accountID: 1, chatID: 42, text: "", forwardIntent: .init(sources: protectedSources))
        let protectedResult = try await value(forwardSummary(box, draft: protected)); XCTAssertNil(protectedResult)
    }
    func testGroupAndChannelMembershipAndTextBansFailClosed() async throws {
        let box = try await open(); let _: Void = try await value(forwardSeed(box))
        let sources = try await value(forwardSources(box))
        for channel in [false, true] {
            for status in 0...2 {
                let chat = try await value(forwardDestination(box, channel: channel, status: status))
                let draft = TelegramComposerDraft(accountID: 1, chatID: chat, text: "comment", forwardIntent: .init(sources: sources))
                let result = try await value(forwardSummary(box, draft: draft))
                XCTAssertEqual(result != nil, status == 0)
            }
            let chat = try await value(forwardDestination(box, channel: channel, banned: [.banSendText]))
            let draft = TelegramComposerDraft(accountID: 1, chatID: chat, text: "comment", forwardIntent: .init(sources: sources))
            let denied = try await value(forwardSummary(box, draft: draft)); XCTAssertNil(denied)
            let _: Int64 = try await value(forwardDestination(box, channel: channel, banned: [.banReadMessages], creator: true))
            let unreadable = try await value(forwardSummary(box, draft: draft)); XCTAssertNil(unreadable)
            if !channel {
                let _: Int64 = try await value(forwardDestination(box, channel: false, deactivated: true, creator: true))
                let inactive = try await value(forwardSummary(box, draft: draft)); XCTAssertNil(inactive)
            }
        }
    }
    func testMediaBanRejectsWholeBatchAndCreatorOverridesSendRestriction() async throws {
        let box = try await open(); let _: Void = try await value(forwardSeed(box, media: [forwardPhoto()]))
        let sources = try await value(forwardSources(box))
        for channel in [false, true] {
            let chat = try await value(forwardDestination(box, channel: channel, banned: [.banSendPhotos]))
            let draft = TelegramComposerDraft(accountID: 1, chatID: chat, text: "allowed comment", forwardIntent: .init(sources: sources))
            let denied = try await value(forwardSummary(box, draft: draft)); XCTAssertNil(denied, "Comment must not queue alone")
            let _: Int64 = try await value(forwardDestination(box, channel: channel, banned: [.banSendPhotos], creator: true))
            let allowed = try await value(forwardSummary(box, draft: draft)); XCTAssertEqual(allowed?.count, 3)
        }
    }
    func testBroadcastAdminNeedsPostingRightAndGroupAdminRetainsNativeOverride() async throws {
        let box = try await open(); let _: Void = try await value(forwardSeed(box))
        let sources = try await value(forwardSources(box))
        for canPost in [false, true] {
            let chat = try await value(forwardDestination(box, channel: true, broadcast: true, admin: true, canPost: canPost))
            let draft = TelegramComposerDraft(accountID: 1, chatID: chat, text: "comment", forwardIntent: .init(sources: sources))
            let result = try await value(forwardSummary(box, draft: draft)); XCTAssertEqual(result != nil, canPost)
        }
        let chat = try await value(forwardDestination(box, channel: false, banned: [.banSendText], admin: true))
        let draft = TelegramComposerDraft(accountID: 1, chatID: chat, text: "comment", forwardIntent: .init(sources: sources))
        let result = try await value(forwardSummary(box, draft: draft)); XCTAssertNotNil(result)
    }
    func testPublicPollRefusedOnlyForBroadcastChannel() async throws {
        let box = try await open(); let _: Void = try await value(forwardSeed(box, media: [forwardPoll(publicity: .public)]))
        let sources = try await value(forwardSources(box))
        let chat = try await value(forwardDestination(box, channel: true, creator: true, broadcast: true))
        let draft = TelegramComposerDraft(accountID: 1, chatID: chat, text: "comment", forwardIntent: .init(sources: sources))
        let denied = try await value(forwardSummary(box, draft: draft)); XCTAssertNil(denied)
        let _: Int64 = try await value(forwardDestination(box, channel: true, creator: true, broadcast: false))
        let supergroup = try await value(forwardSummary(box, draft: draft)); XCTAssertNotNil(supergroup)
        let _: Void = try await value(forwardSeed(box, media: [forwardPoll(publicity: .anonymous)]))
        let anonymousSources = try await value(forwardSources(box))
        let _: Int64 = try await value(forwardDestination(box, channel: true, creator: true, broadcast: true))
        let anonymous = TelegramComposerDraft(accountID: 1, chatID: chat, text: "comment", forwardIntent: .init(sources: anonymousSources))
        let allowed = try await value(forwardSummary(box, draft: anonymous)); XCTAssertNotNil(allowed)
    }

    func testForwardingPaidSourceToSavedNeverCopiesItsOldCharge() async throws {
        let box = try await open(); let _: Void = try await value(forwardPaidSourceSeed(box))
        let ids = try await value(forwardPaidSourceQueue(box, destination: 1, price: nil))
        XCTAssertEqual(ids.compactMap { $0 }.count, 1)
        let id = try XCTUnwrap(ids.first.flatMap { $0 })
        let result = try await value(forwardPaidSourceSummary(box, id: id))
        XCTAssertEqual(result?.fees, []); XCTAssertEqual(result?.originalFees, [17])
        XCTAssertEqual(result?.hideNames, true)
    }
    func testForwardingPaidSourceUsesOnlyExplicitCurrentDestinationCharge() async throws {
        let box = try await open(); let _: Void = try await value(forwardPaidSourceSeed(box))
        let ids = try await value(forwardPaidSourceQueue(box, destination: 42, price: 3))
        XCTAssertEqual(ids.compactMap { $0 }.count, 1)
        let id = try XCTUnwrap(ids.first.flatMap { $0 })
        let result = try await value(forwardPaidSourceSummary(box, id: id))
        XCTAssertEqual(result?.fees, [3]); XCTAssertEqual(result?.originalFees, [17])
        XCTAssertEqual(result?.hideNames, true)
    }

}

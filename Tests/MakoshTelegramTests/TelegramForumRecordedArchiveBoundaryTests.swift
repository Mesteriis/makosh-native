import XCTest
import Foundation
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func forumRecordedPeer() -> TelegramChannel {
    TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(43)),
        accessHash: nil, title: "Synthetic recorded forum", username: nil, photo: [], creationDate: 0, version: 1,
        participationStatus: .member, info: .group(.init(flags: [])), flags: [.isForum], restrictionInfo: nil,
        adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil,
        sendPaidMessageStars: nil, linkedMonoforumId: nil)
}
private nonisolated func forumRecordedUser(_ number: Int64) -> TelegramUser {
    TelegramUser(id: PeerId(number), accessHash: nil, firstName: "Synthetic", lastName: nil,
        username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil,
        usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
        profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func forumRecordedSeed(_ box: Postbox) -> Signal<TelegramMessageActionSource?, NoError> {
    box.transaction { transaction in
        let forum = forumRecordedPeer(), author = forumRecordedUser(7)
        transaction.updatePeersInternal([forumRecordedUser(1), author, forum], update: { _, next in next })
        transaction.updatePeerCachedData(peerIds: [forum.id], update: { _, _ in CachedChannelData() })
        let id = MessageId(peerId: forum.id, namespace: Namespaces.Message.Cloud, id: 107)
        let photo = TelegramMediaImage(imageId: .init(namespace: Namespaces.Media.LocalImage, id: 500),
            representations: [], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        _ = transaction.addMessages([StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: 7,
            timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
            authorId: author.id, text: "prefix 😀 quoted tail",
            attributes: [TextEntitiesMessageAttribute(entities: [.init(range: 10..<16, type: .Bold)])],
            media: [photo])], location: .Random)
        let topic = MessageHistoryThreadData(creationDate: 1, isOwnedByMe: false, author: author.id,
            info: .init(title: "Synthetic topic", icon: nil, iconColor: 0), incomingUnreadCount: 0,
            isMarkedUnread: false, maxIncomingReadId: 0, maxKnownMessageId: 107, maxOutgoingReadId: 0,
            isClosed: false, isHidden: false, notificationSettings: .init(muteState: .unmuted,
                messageSound: .default, displayPreviews: .default, storySettings: .default), isMessageFeeRemoved: false)
        guard let data = CodableEntry(topic) else { return nil }
        transaction.setMessageHistoryThreadInfo(peerId: forum.id, threadId: 7,
            info: .init(data: data, summary: .init(totalUnreadCount: 0, isMarkedUnread: false,
                mutedUntil: nil, maxOutgoingReadId: 0)))
        guard let message = transaction.getMessage(id) else { return nil }
        let plain = telegramMessageActionSource(message, accountID: 1, chatID: forum.id.toInt64())
        guard let formatted = plain.metadata.formattedText,
            let quote = TelegramReplyQuote(source: formatted, selection: .init(location: 7, length: 9)) else { return nil }
        return plain.quoting(quote)
    }
}
private nonisolated func forumRecordedMessages(_ box: Postbox, ids: [MessageId]) -> Signal<[Message], NoError> {
    box.transaction { transaction in ids.compactMap { transaction.getMessage($0) } }
}
private nonisolated func forumRecordedHasPendingMessages(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.getTopPeerMessageIndex(peerId: forumRecordedPeer().id, namespace: Namespaces.Message.Local) != nil
    }
}

// The upload receipt and shared authorization both execute in the actual native
// insertion/commit transactions. Only Account/network transport is substituted.
private nonisolated func forumRecordedEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
    messages: [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError> {
    let context = TelegramSendContext(accountID: 1, chatID: receipt.target.chatID,
        threadID: receipt.target.selectedThreadID, submissionRevision: receipt.draft.revision, messageCount: messages.count)
    return box.transaction { transaction in
        telegramNativeSendPreparation(transaction: transaction, context: context, messages: messages, files: [:], consent: nil)
    } |> mapToSignal { preparation in
        guard let preparation else { return .single(.rejected) }
        return telegramUploadBatchEnqueue(receipt: receipt, messages: messages, now: { 100 }) { _, admission, commit in
            telegramNativePreparedEnqueue(preparation: preparation, authorization: .init(context: context, consent: nil),
                specificAdmission: admission, specificCommit: commit) { prepared, combinedAdmission, combinedCommit in
                enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
                    peerId: PeerId(context.chatID), messages: prepared,
                    transactionAdmission: combinedAdmission, transactionCommit: combinedCommit)
            } |> map { $0 ?? [nil] }
        }
    }
}

@MainActor final class TelegramForumRecordedArchiveBoundaryTests: TelegramSourceFactsIntegrationTestCase {
    private enum Payload { case voice, round, archive }

    func testQuotedForumVoiceRestoresAndQueuesWithS3Disabled() async throws { try await exercise(.voice, s3: false) }
    func testQuotedForumVoiceRestoresAndQueuesWithS3Enabled() async throws { try await exercise(.voice, s3: true) }
    func testQuotedForumRoundRestoresAndQueuesWithS3Disabled() async throws { try await exercise(.round, s3: false) }
    func testQuotedForumRoundRestoresAndQueuesWithS3Enabled() async throws { try await exercise(.round, s3: true) }
    func testQuotedForumArchiveRestoresAndQueuesWithS3Disabled() async throws { try await exercise(.archive, s3: false) }
    func testQuotedForumArchiveRestoresAndQueuesWithS3Enabled() async throws { try await exercise(.archive, s3: true) }

    private func exercise(_ payload: Payload, s3: Bool) async throws {
        let fixture = try await sourceFactsArchive(), chatID = forumRecordedPeer().id.toInt64()
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "1", conversationID: String(chatID), messageID: "synthetic-policy")
        try await fixture.archive.setConversationFileSavingEnabled(identity: identity, enabled: s3)
        var saved: TelegramPendingUploadDraft?, uploadTarget: TelegramUploadTarget?
        var expectedItemBytes: [Data] = [], expectedPayload = Data()
        weak var previous: Postbox?
        do {
            let box = try await sourceFactsOpen(fixture.postboxPath); previous = box
            let sourceValue = try await sourceFactsValue(forumRecordedSeed(box)), source = try XCTUnwrap(sourceValue)
            let target = TelegramUploadTarget(accountID: 1, chatID: chatID, title: "Synthetic recorded forum",
                replySource: source, selectedThreadID: 7)
            uploadTarget = target
            let original = TelegramComposerDraft(accountID: 1, chatID: chatID, input: .empty,
                threadID: 7, replyTarget: .init(source: source))
            let items: [TelegramUploadBatchItem]
            let presentation: TelegramUploadPresentation
            switch payload {
            case .voice:
                var pcm = [Int16](repeating: 0, count: 48_137)
                for index in 0..<100 { pcm[index] = 1_000 }
                let file = try await TelegramRecordedVoiceIO.prepare(samples: pcm, isOneTime: false)
                items = [.init(id: file.id, file: file)]; presentation = .file
            case .round:
                let bytes = try await recordedRoundVideoFixtureBytes(duration: 1.25)
                let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes, isOneTime: false)
                items = [.init(id: file.id, file: file)]; presentation = .media
            case .archive:
                items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "Synthetic first member"),
                    try await sourceFactsDocument(fixture, name: ".second.txt", text: "Synthetic second member")]
                presentation = .file
            }
            defer { items.forEach { try? $0.discard() } }
            expectedItemBytes = try items.map { try Data(contentsOf: $0.file.url) }
            let store = fixture.session(box), preparationID = UUID()
            if payload == .archive {
                try await store.prepare(preparationID: preparationID, items: items, isGrouped: false, presentation: presentation,
                    target: target, captionInput: .empty, originalDraft: original,
                    captionPolicy: try .init(maximumUTF16Count: 1024))
                try await store.updatePresentation(preparationID: preparationID, orderedIDs: items.map(\.id),
                    previousPresentation: .file, previousGrouping: false, presentation: .archive, isGrouped: false, target: target)
            } else {
                try await store.prepare(preparationID: preparationID, items: items, isGrouped: false, presentation: presentation,
                    target: target, captionInput: .empty, originalDraft: original)
            }
            let readyValue = try await store.load(chatID: chatID), ready = try XCTUnwrap(readyValue)
            XCTAssertEqual(ready.schemaVersion, 21); XCTAssertEqual(ready.threadID, 7)
            XCTAssertEqual(ready.replyTarget, .init(source: source)); XCTAssertEqual(ready.originalDraft, original)
            let readyBundle = try await store.restoreBundle(draft: ready)
            defer { try? readyBundle.discard() }
            if payload == .archive {
                let archive = try XCTUnwrap(readyBundle.archive)
                XCTAssertEqual(archive.members.map(\.entryName), ["first.txt", ".second.txt"])
                expectedPayload = try Data(contentsOf: archive.file.url)
                for name in ["first.txt", ".second.txt"] {
                    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(name))
                }
            } else { expectedPayload = try XCTUnwrap(expectedItemBytes.first) }
            try await store.save(preparationID: preparationID, chatID: chatID, captionInput: .empty, disposition: .submissionStarted)
            saved = try await store.load(chatID: chatID)
        }
        try await released { previous }
        let frozen = try XCTUnwrap(saved), target = try XCTUnwrap(uploadTarget)
        var records = frozen.items.flatMap { [$0.file] + ($0.originalFile.map { [$0] } ?? []) }
        if let archive = frozen.archive { records.append(archive.file) }
        XCTAssertTrue(records.allSatisfy { $0.state == (s3 ? .stored : .local) })
        XCTAssertTrue(records.allSatisfy { $0.identity.conversationID == String(chatID) })
        for record in records {
            let head = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
            if s3 { XCTAssertNotNil(head) } else { XCTAssertNil(head) }
        }
        var accepted: TelegramPendingUploadDraft?
        do {
            let box = try await sourceFactsOpen(fixture.postboxPath); previous = box
            let store = fixture.session(box), loaded = try await store.load(chatID: chatID)
            XCTAssertEqual(loaded, frozen)
            let localBefore = try fixture.localRecords(), eventsBefore = try fileEvents(fixture)
            let bundle = try await store.restoreBundle(draft: frozen)
            defer { try? bundle.discard() }
            XCTAssertEqual(try bundle.items.map { try Data(contentsOf: $0.file.url) }, expectedItemBytes)
            XCTAssertEqual(bundle.items.map(\.sourceFacts), frozen.items.map(\.sourceFacts))
            XCTAssertEqual(bundle.items.map { $0.file.metadata }, frozen.items.map(\.metadata))
            if payload == .archive { XCTAssertEqual(try Data(contentsOf: XCTUnwrap(bundle.archive?.file.url)), expectedPayload) }
            XCTAssertEqual(try fixture.localRecords(), localBefore); XCTAssertEqual(try fileEvents(fixture), eventsBefore)
            let pendingBefore = try await sourceFactsValue(forumRecordedHasPendingMessages(box))
            XCTAssertFalse(pendingBefore, "Restoration must not enqueue anything")
            let result = try await submit(box: box, bundle: bundle, draft: frozen, target: target)
            guard case let .accepted(ids) = result else { return XCTFail("Quoted forum payload was not accepted: \(result)") }
            XCTAssertEqual(ids.count, 1)
            let messages = try await sourceFactsValue(forumRecordedMessages(box, ids: ids.map(\.nativeID)))
            let message = try XCTUnwrap(messages.first)
            XCTAssertEqual(message.threadId, 7); XCTAssertEqual(message.text, ""); XCTAssertNil(message.groupingKey)
            XCTAssertTrue(message.attributes.allSatisfy { !($0 is PaidStarsMessageAttribute) && !($0 is AutoclearTimeoutMessageAttribute) })
            let reply = try XCTUnwrap(message.attributes.first { $0 is ReplyMessageAttribute } as? ReplyMessageAttribute)
            XCTAssertEqual(reply.messageId, .init(peerId: PeerId(chatID), namespace: Namespaces.Message.Cloud, id: 107))
            XCTAssertEqual(reply.threadMessageId, .init(peerId: PeerId(chatID), namespace: Namespaces.Message.Cloud, id: 7))
            XCTAssertTrue(reply.isQuote); XCTAssertEqual(reply.quote?.text, "😀 quoted"); XCTAssertEqual(reply.quote?.offset, 7)
            XCTAssertEqual(reply.quote?.entities, [.init(range: 3..<9, type: .Bold)])
            XCTAssertEqual(reply.quote?.media?.id?.namespace, Namespaces.Media.LocalImage)
            XCTAssertEqual(reply.quote?.media?.id?.id, 500)
            let native = try XCTUnwrap(message.media.first as? TelegramMediaFile)
            switch payload {
            case .voice:
                var waveform = Data(repeating: 0, count: 63); waveform[0] = 0x0c
                XCTAssertEqual(native.mimeType, "audio/ogg")
                XCTAssertEqual(native.attributes, [.Audio(isVoice: true, duration: 1, title: nil, performer: nil, waveform: waveform)])
                XCTAssertTrue(native.previewRepresentations.isEmpty)
            case .round:
                XCTAssertEqual(native.mimeType, "video/mp4")
                XCTAssertEqual(native.attributes, [.Video(duration: 2, size: .init(width: 200, height: 200),
                    flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)])
                XCTAssertEqual(native.previewRepresentations.count, 1)
                for preview in native.previewRepresentations {
                    let bytes = try await cachedBytes(box, resource: preview.resource)
                    XCTAssertFalse(bytes.isEmpty, "The restored round must retain its native preview")
                }
            case .archive:
                XCTAssertEqual(native.mimeType, "application/zip")
                XCTAssertTrue(native.previewRepresentations.isEmpty)
                XCTAssertTrue(native.attributes.contains { if case let .FileName(name) = $0 { return name.hasSuffix(".zip") }; return false })
            }
            let cached = try await cachedBytes(box, resource: native.resource)
            XCTAssertEqual(cached, expectedPayload)
            accepted = try await store.load(chatID: chatID)
            XCTAssertEqual(accepted?.disposition, .acceptedBatch(messageIDs: ids)); XCTAssertEqual(accepted?.items, frozen.items)
            XCTAssertEqual(accepted?.threadID, 7); XCTAssertEqual(accepted?.replyTarget, frozen.replyTarget)
            let stale = try await submit(box: box, bundle: bundle, draft: frozen, target: target)
            XCTAssertEqual(stale, .rejected, "The old restored snapshot must not enqueue again")
            let unchanged = try await store.load(chatID: chatID); XCTAssertEqual(unchanged, accepted)
        }
        try await released { previous }
        do {
            let box = try await sourceFactsOpen(fixture.postboxPath); previous = box
            let final = try await fixture.session(box).load(chatID: chatID)
            XCTAssertEqual(final, accepted, "The complete native receipt must survive another encrypted restart")
        }
        try await released { previous }
        if !s3 {
            XCTAssertEqual(try fileEvents(fixture), [["0"]])
            try await fixture.archive.setConversationFileSavingEnabled(identity: identity, enabled: true)
            let promoted = try await fixture.archive.resume(); XCTAssertEqual(promoted, 0)
            for record in records {
                let head = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                XCTAssertNil(head, "Turning storage on later must not promote a preparation captured with S3 disabled")
            }
            XCTAssertEqual(try fileEvents(fixture), [["0"]])
        }
    }

    private func submit(box: Postbox, bundle: TelegramRecoveredUploadBundle, draft: TelegramPendingUploadDraft,
        target: TelegramUploadTarget) async throws -> TelegramUploadBatchEvent {
        let done = expectation(description: "Quoted forum native receipt")
        var result: TelegramUploadBatchEvent?
        let operation = TelegramUploadBatchSubmission(postbox: box, accountID: 1, bundle: bundle, draft: draft,
            target: target, enqueue: { receipt, messages in forumRecordedEnqueue(box, receipt: receipt, messages: messages) }) { event in
                switch event { case .accepted, .rejected, .uncertain: result = event; done.fulfill(); default: break }
            }
        defer { operation.stop() }
        await fulfillment(of: [done], timeout: 30)
        return try XCTUnwrap(result)
    }
    private func cachedBytes(_ box: Postbox, resource: any MediaResource) async throws -> Data {
        let resourceData = try await sourceFactsValue(box.mediaBox.resourceData(resource, pathExtension: nil,
            option: .complete(waitUntilFetchStatus: false)))
        XCTAssertTrue(resourceData.complete)
        return try Data(contentsOf: URL(fileURLWithPath: resourceData.path))
    }
    private func released(_ previous: () -> Postbox?) async throws {
        // Read the caller's weak storage on each turn; retaining a Postbox
        // parameter across suspension would itself prevent database closure.
        for _ in 0..<100 {
            if previous() == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(previous(), "The encrypted Postbox must be closed before reopening its path")
    }
    private func fileEvents(_ fixture: SourceFactsTestArchive) throws -> [[String]] {
        try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events")
    }
}

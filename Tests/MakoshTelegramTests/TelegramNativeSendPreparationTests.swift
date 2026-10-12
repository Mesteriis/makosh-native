import XCTest
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func sendPreparationUser(_ id: Int64, premium: Bool) -> TelegramUser {
    TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil,
        phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: premium ? [.isPremium] : [],
        emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
        profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func sendPreparationFile() -> TelegramMediaFile {
    TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: 100), partialReference: nil,
        resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 100, accessHash: 53, size: 100,
            fileReference: Data([1, 2]), fileName: "synthetic.webp"),
        previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil,
        mimeType: "image/webp", size: 100, attributes: [.CustomEmoji(isPremium: true,
            isSingleColor: false, alt: "🦊", packReference: nil)], alternativeRepresentations: [])
}
private nonisolated func sendPreparationMessage(_ text: String = "Hello", custom: Bool = false) -> EnqueueMessage {
    .message(text: text, attributes: custom ? [TextEntitiesMessageAttribute(entities: [
        .init(range: 0..<2, type: .CustomEmoji(stickerPack: nil, fileId: 100))])] : [], inlineStickers: [:],
        mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil,
        localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
}
private nonisolated func sendPreparationSeed(_ box: Postbox, premium: Bool) -> Signal<Void, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([sendPreparationUser(1, premium: premium),
            sendPreparationUser(42, premium: false)], update: { _, new in new })
        transaction.updatePeerCachedData(peerIds: Set([PeerId(42)])) { _, _ in CachedUserData() }
        let file = sendPreparationFile()
        _ = transaction.updateMedia(file.fileId, update: file)
        transaction.storeMediaIfNotPresent(media: file)
    }
}
private nonisolated func sendPreparationQueue(_ box: Postbox, prepared: TelegramNativeSendPreparation)
    -> Signal<[MessageId?], NoError> {
    enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
        peerId: PeerId(42), messages: prepared.messages,
        transactionAdmission: { prepared.validate(transaction: $0) })
}

private nonisolated func sendPreparationPrices(_ box: Postbox, context: TelegramSendContext, consent: TelegramPaidSendConsent) -> Signal<[Int64]?, NoError> {
    box.transaction { transaction in
            let forward = EnqueueMessage.forward(source: .init(peerId: PeerId(7), namespace: 0, id: 8),
                threadId: nil, grouping: .none, attributes: [ForwardOptionsMessageAttribute(hideNames: true, hideCaptions: true)], correlationId: nil)
            guard let prepared = telegramNativeSendPreparation(transaction: transaction, context: context,
                messages: [sendPreparationMessage(), forward], files: [:], consent: consent) else { return nil }
            let options = prepared.messages[1].attributes.compactMap { $0 as? ForwardOptionsMessageAttribute }.first
            guard options?.hideNames == true, options?.hideCaptions == true else { return nil }
            return prepared.messages.map { $0.attributes.compactMap { $0 as? PaidStarsMessageAttribute }.first?.stars.value ?? -1 }
    }
}

private nonisolated func sendPreparationInvalid(_ box: Postbox, context: TelegramSendContext, other: TelegramSendContext) -> Signal<Bool, NoError> {
    box.transaction { transaction in
            let consent = TelegramPaidSendConsent(id: UUID(), context: other, perMessageStars: 3, totalStars: 3)
            let paid = sendPreparationMessage().withUpdatedAttributes { $0 + [PaidStarsMessageAttribute(stars: .init(value: 3, nanos: 0), postponeSending: false)] }
            return telegramNativeSendPreparation(transaction: transaction, context: context,
                messages: [sendPreparationMessage()], files: [:], consent: consent) == nil
                && telegramNativeSendPreparation(transaction: transaction, context: context,
                    messages: [paid], files: [:], consent: nil) == nil
    }
}

private nonisolated func sendPreparationEmoji(_ box: Postbox, context: TelegramSendContext) -> Signal<TelegramNativeSendPreparation?, NoError> {
    box.transaction { transaction in
        telegramNativeSendPreparation(transaction: transaction, context: context,
            messages: [sendPreparationMessage("🦊", custom: true)], files: [100: sendPreparationFile()], consent: nil)
    }
}

private nonisolated func sendPreparationAssociated(_ box: Postbox, ids: [MessageId?]) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        ids.compactMap { $0 }.first.flatMap { transaction.getMessage($0) }?
            .associatedMedia[MediaId(namespace: Namespaces.Media.CloudFile, id: 100)] is TelegramMediaFile
    }
}

private nonisolated func sendPreparationSharedQueue(_ box: Postbox, prepared: TelegramNativeSendPreparation,
    committed: Atomic<Bool>, corruptResult: Bool = false) -> Signal<[MessageId?]?, NoError> {
    telegramNativePreparedEnqueue(preparation: prepared, authorization: .init(context: prepared.context, consent: nil),
        specificAdmission: { _ in true }, specificCommit: { _, _ in _ = committed.swap(true) },
        enqueue: { messages, admission, commit in
            enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false,
                timestamp: 100, peerId: PeerId(42), messages: messages,
                transactionAdmission: admission, transactionCommit: commit)
                |> map { corruptResult ? [nil] : $0 }
        })
}

private nonisolated func sendPreparationEditSource(_ box: Postbox, update: Bool = false) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let id = MessageId(peerId: PeerId(42), namespace: Namespaces.Message.Cloud, id: 10)
        let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: Int32(Date().timeIntervalSince1970) - 1, flags: [], tags: [], globalTags: [],
            localTags: [], forwardInfo: nil, authorId: PeerId(1), text: update ? "Later edit" : "Original",
            attributes: [], media: [])
        if update { transaction.updateMessage(id) { _ in .update(message) } }
        else { _ = transaction.addMessages([message], location: .Random) }
    }
}
private nonisolated func sendPreparationReadEditSource(_ box: Postbox) -> Signal<TelegramMessageActionSource?, NoError> {
    box.transaction { transaction in
        transaction.getMessage(.init(peerId: PeerId(42), namespace: Namespaces.Message.Cloud, id: 10)).map {
            telegramMessageActionSource($0, accountID: 1, chatID: 42)
        }
    }
}
private nonisolated func sendPreparationEditAdmission(_ box: Postbox, source: TelegramMessageActionSource,
    content: TelegramMessageEditContent) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        telegramNativeEditInlineStickers(transaction: transaction, accountID: 1, source: source,
            content: content, files: [100: sendPreparationFile()])?[.init(namespace: Namespaces.Media.CloudFile, id: 100)] is TelegramMediaFile
    }
}

@MainActor final class TelegramNativeSendPreparationTests: TelegramSourceFactsIntegrationTestCase {
    private func box() async throws -> Postbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try await sourceFactsOpen(root.appendingPathComponent("postbox"))
    }
    private func context(count: Int = 1) -> TelegramSendContext {
        .init(accountID: 1, chatID: 42, threadID: nil, submissionRevision: UUID(), messageCount: count)
    }
    // Catches stamping only text while a forwarded message escapes the displayed total.
    func testExplicitConsentStampsEveryMessageAndRetainsExistingAttributes() async throws {
        let box = try await box(), context = context(count: 2)
        let consent = TelegramPaidSendConsent(id: UUID(), context: context, perMessageStars: 3, totalStars: 6)
        let result = try await sourceFactsValue(sendPreparationPrices(box, context: context, consent: consent))
        XCTAssertEqual(result, [3, 3])
    }
    // Catches manufacturing consent for a changed submission or stacking payment attributes.
    func testChangedContextOrAlreadyPaidPayloadIsRejected() async throws {
        let box = try await box(), context = context()
        let other = self.context()
        let denied = try await sourceFactsValue(sendPreparationInvalid(box, context: context, other: other))
        XCTAssertTrue(denied)
    }
    // Catches a descriptor-only emoji send, dropped associated media or a downgrade after preparation.
    func testPreparedCustomEmojiUsesNativeDocumentAndRechecksTierAtQueueInsertion() async throws {
        let box = try await box(), context = context()
        _ = try await sourceFactsValue(sendPreparationSeed(box, premium: true))
        let prepared = try await sourceFactsValue(sendPreparationEmoji(box, context: context))
        guard let prepared else { XCTFail("Resolved native emoji must prepare"); return }
        let ids = try await sourceFactsValue(sendPreparationQueue(box, prepared: prepared))
        XCTAssertEqual(ids.compactMap { $0 }.count, 1)
        let associated = try await sourceFactsValue(sendPreparationAssociated(box, ids: ids))
        XCTAssertTrue(associated)
        _ = try await sourceFactsValue(sendPreparationSeed(box, premium: false))
        let rejected = try await sourceFactsValue(sendPreparationQueue(box, prepared: prepared))
        XCTAssertTrue(rejected.isEmpty)
    }
    // Uses the real queue insertion with the same preparation/authorization
    // composition used by every Account adapter, including its final receipt.
    func testSharedNativeBoundaryCommitsCompleteQueueAndRefusesChangedTier() async throws {
        let box = try await box(), context = context(), committed = Atomic(value: false)
        _ = try await sourceFactsValue(sendPreparationSeed(box, premium: true))
        guard let prepared = try await sourceFactsValue(sendPreparationEmoji(box, context: context)) else {
            return XCTFail("Native document must prepare")
        }
        let ids = try await sourceFactsValue(sendPreparationSharedQueue(box, prepared: prepared, committed: committed))
        XCTAssertEqual(ids?.compactMap { $0 }.count, 1); XCTAssertTrue(committed.with { $0 })
        _ = committed.swap(false)
        _ = try await sourceFactsValue(sendPreparationSeed(box, premium: false))
        let rejected = try await sourceFactsValue(sendPreparationSharedQueue(box, prepared: prepared, committed: committed))
        XCTAssertEqual(rejected, []); XCTAssertFalse(committed.with { $0 })
    }
    // A native insertion may have committed even when its callback is damaged.
    // It must retain the draft and receipt instead of reporting known rejection.
    func testSharedNativeBoundaryReturnsUnknownForIncompleteCallbackAfterCommit() async throws {
        let box = try await box(), context = context(), committed = Atomic(value: false)
        _ = try await sourceFactsValue(sendPreparationSeed(box, premium: true))
        guard let prepared = try await sourceFactsValue(sendPreparationEmoji(box, context: context)) else {
            return XCTFail("Native document must prepare")
        }
        let result = try await sourceFactsValue(sendPreparationSharedQueue(box, prepared: prepared,
            committed: committed, corruptResult: true))
        XCTAssertNil(result); XCTAssertTrue(committed.with { $0 })
    }

    // Preparing a caption keeps the typed emoji entity; it still carries no
    // outgoing document authority until the shared native insertion validates it.
    func testCustomEmojiCaptionPreservesEntityUntilNativeAdmission() throws {
        let formatted = try TelegramFormattedText(text: "🦊", entities: [
            .init(offset: 0, length: 2, kind: .customEmoji(stickerPack: nil, fileID: 100))])
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
        let reference = AnyMediaReference.standalone(media: sendPreparationFile())
        guard let message = telegramUploadMessage(caption: formatted, reference: reference, target: target,
            replySource: nil, allowCustomEmoji: true) else { return XCTFail("Typed custom emoji must survive media preparation") }
        XCTAssertEqual(message.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities,
            formatted.engineEntities())
        XCTAssertFalse(telegramFormattedCaptionCanSend(formatted))
        XCTAssertFalse(telegramFormattedTextCanSend(formatted))
    }

    func testEditResolvesNativeCustomDocumentAndRejectsDowngradeOrChangedSource() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(sendPreparationSeed(box, premium: true))
        _ = try await sourceFactsValue(sendPreparationEditSource(box))
        let captured = try await sourceFactsValue(sendPreparationReadEditSource(box))
        let source = try XCTUnwrap(captured)
        let formatted = try TelegramFormattedText(text: "🦊", entities: [.init(offset: 0, length: 2,
            kind: .customEmoji(stickerPack: nil, fileID: 100))])
        let content = try XCTUnwrap(TelegramMessageEditContent(action: .editFormatted(formatted), source: source))
        let accepted = try await sourceFactsValue(sendPreparationEditAdmission(box, source: source, content: content))
        XCTAssertTrue(accepted)
        _ = try await sourceFactsValue(sendPreparationSeed(box, premium: false))
        let downgrade = try await sourceFactsValue(sendPreparationEditAdmission(box, source: source, content: content))
        XCTAssertFalse(downgrade)
        _ = try await sourceFactsValue(sendPreparationSeed(box, premium: true))
        _ = try await sourceFactsValue(sendPreparationEditSource(box, update: true))
        let stale = try await sourceFactsValue(sendPreparationEditAdmission(box, source: source, content: content))
        XCTAssertFalse(stale)
    }

}

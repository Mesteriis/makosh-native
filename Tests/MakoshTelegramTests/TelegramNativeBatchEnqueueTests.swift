import XCTest
import Foundation
import ImageIO
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func batchNativePeer(_ id: PeerId) -> TelegramUser {
    TelegramUser(id: id, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil)
}
private func batchNativeSeed(_ box: Postbox, draft: TelegramPendingUploadDraft) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([batchNativePeer(PeerId(1)), batchNativePeer(PeerId(42))], update: { _, new in new })
        if case .success = telegramPendingUploadWrite(transaction: transaction, accountID: draft.accountID,
            draft: draft, expectedRevision: nil) { return true }
        return false
    }
}
private func batchNativeSeedPointerOnly(_ box: Postbox, draft: TelegramPendingUploadDraft) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        if case .success = telegramPendingUploadWrite(transaction: transaction, accountID: draft.accountID,
            draft: draft, expectedRevision: nil) { return true }
        return false
    }
}
private func batchNativeEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt, messages: [EnqueueMessage],
                               dropLastACK: Bool = false, rewriteReplyThread: Bool = false) -> Signal<([MessageId?], Bool), NoError> {
    let accepted = Atomic<Bool>(value: false)
    return enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
        peerId: PeerId(receipt.target.chatID), messages: messages, transactionAdmission: { receipt.validate(transaction: $0) },
        transactionCommit: { transaction, ids in
            if rewriteReplyThread, let last = ids.last, let id = last, let queued = transaction.getMessage(id) {
                let attributes = queued.attributes.map { attribute -> MessageAttribute in
                    guard let reply = attribute as? ReplyMessageAttribute else { return attribute }
                    return ReplyMessageAttribute(messageId: reply.messageId,
                        threadMessageId: MessageId(peerId: PeerId(42), namespace: Namespaces.Message.Cloud, id: 999),
                        quote: reply.quote, isQuote: reply.isQuote, todoItemId: reply.todoItemId)
                }
                transaction.updateMessage(id) { _ in .update(StoreMessage(id: id, globallyUniqueId: nil,
                    groupingKey: queued.groupingKey, threadId: queued.threadId, timestamp: queued.timestamp,
                    flags: [.Unsent], tags: queued.tags, globalTags: queued.globalTags, localTags: queued.localTags,
                    forwardInfo: nil, authorId: PeerId(1), text: queued.text, attributes: attributes, media: queued.media)) }
            }
            _ = accepted.swap(receipt.acknowledge(transaction: transaction, messageIDs: dropLastACK ? Array(ids.dropLast()) : ids))
        }) |> map { ($0, accepted.with { $0 }) }
}
private func batchNativeRead(_ box: Postbox, ids: [MessageId], chatID: Int64 = 42) -> Signal<(TelegramPendingUploadDraft?, [Message]), NoError> {
    box.transaction { transaction in
        let draft = try? telegramPendingUploadRead(transaction: transaction, accountID: 1, chatID: chatID).get()
        return (draft ?? nil, ids.compactMap { transaction.getMessage($0) })
    }
}
private func batchNativeReplacingMedia(_ message: EnqueueMessage, _ media: Media) -> EnqueueMessage {
    guard case let .message(text, attributes, stickers, _, thread, reply, story, key, correlation, bubbles) = message else {
        preconditionFailure("Fixture must be an outgoing upload")
    }
    return .message(text: text, attributes: attributes, inlineStickers: stickers, mediaReference: .standalone(media: media),
        threadId: thread, replyToMessageId: reply, replyToStoryId: story, localGroupingKey: key,
        correlationId: correlation, bubbleUpEmojiOrStickersets: bubbles)
}
private func batchNativeReplySource(_ box: Postbox) -> Signal<TelegramMessageActionSource?, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([batchNativePeer(PeerId(1)), batchNativePeer(PeerId(42))], update: { _, new in new })
        let id = MessageId(peerId: PeerId(42), namespace: Namespaces.Message.Cloud, id: 7)
        _ = transaction.addMessages([StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: 77,
            timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
            authorId: PeerId(42), text: "Synthetic reply source", attributes: [], media: [])], location: .Random)
        return transaction.getMessage(id).map { TelegramMessageActionSource(metadata: telegramMessageActionMetadata($0,
            limits: currentLimitsConfiguration(transaction: transaction)), accountID: 1, chatID: 42) }
    }
}

private func batchNativeMigratedReplySource(_ box: Postbox, targetID: PeerId, media: [Media]) -> Signal<TelegramMessageActionSource?, NoError> {
    box.transaction { transaction in
        let oldID = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(71))
        let group = TelegramGroup(id: oldID, title: "Synthetic old group", photo: [], participantCount: 2,
            role: .member, membership: .Member, flags: [], defaultBannedRights: nil,
            migrationReference: .init(peerId: targetID, accessHash: 7), creationDate: 0, version: 1)
        let channel = TelegramChannel(id: targetID, accessHash: nil, title: "Synthetic migrated group", username: nil,
            photo: [], creationDate: 0, version: 1, participationStatus: .member,
            info: .group(TelegramChannelGroupInfo(flags: [])), flags: [], restrictionInfo: nil,
            adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil,
            verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
        transaction.updatePeersInternal([batchNativePeer(PeerId(1)), group, channel], update: { _, new in new })
        let id = MessageId(peerId: oldID, namespace: Namespaces.Message.Cloud, id: 7)
        _ = transaction.addMessages([StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: 77,
            timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
            authorId: PeerId(1), text: "Synthetic migrated reply", attributes: [], media: media)], location: .Random)
        return transaction.getMessage(id).map { TelegramMessageActionSource(metadata: telegramMessageActionMetadata($0,
            limits: currentLimitsConfiguration(transaction: transaction)), accountID: 1, chatID: targetID.toInt64()) }
    }
}

@MainActor final class TelegramNativeBatchEnqueueTests: XCTestCase {
    // Catches sharing one derivative identity across different files in the atomic batch capability.
    func testReceiptRejectsSharedOrCrossOriginalWebPPreviewIdentities() async throws {
        let root = try root()
        let (draft, items) = try await fixture(root, modes: [.file, .file], grouped: false, webP: true)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        for previewIDs: [Int64] in [[900, 900], [900, 801]] {
            var resources: [TelegramUploadBatchResource] = []
            for (index, item) in items.enumerated() {
                let preview = TelegramUploadVideoThumbnailResource(id: previewIDs[index], width: 320, height: 160, size: 128)
                let media = try XCTUnwrap(telegramUploadMedia(item.file, webPPreview: preview, resourceID: Int64(801 + index)))
                resources.append(.init(item: item, plaintextSHA256: draft.items[index].file.plaintextSHA256,
                    prepared: .init(resource: media.0, reference: media.1, videoThumbnail: nil, webPPreview: preview)))
            }
            XCTAssertThrowsError(try TelegramUploadBatchEnqueueReceipt(draft: draft,
                target: .init(accountID: 1, chatID: 42, title: "Synthetic"), resources: resources, groupKeys: []))
        }
    }

    // Catches admitting a derivative in a wrong role, an invalid cache identity, or aliasing its original.
    func testWebPMapperRejectsWrongRoleMalformedPreviewAndAliasedOriginal() async throws {
        let root = try root()
        let (_, items) = try await fixture(root, modes: [.file], grouped: false, webP: true)
        let typed = items[0].file
        defer { try? TelegramUploadFileIO.discard(typed) }
        let preview = TelegramUploadVideoThumbnailResource(id: 900, width: 320, height: 160, size: 128)
        let generic = TelegramUploadFile(id: typed.id, name: typed.name, size: typed.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: typed.url, directory: typed.directory)
        XCTAssertNil(telegramUploadMedia(generic, webPPreview: preview, resourceID: 801))
        XCTAssertNil(telegramUploadMedia(typed, webPPreview: preview, resourceID: 900))
        for invalid in [
            TelegramUploadVideoThumbnailResource(id: 901, width: 0, height: 160, size: 128),
            TelegramUploadVideoThumbnailResource(id: 901, width: 321, height: 160, size: 128),
            TelegramUploadVideoThumbnailResource(id: 901, width: 320, height: 160, size: 1_048_577)
        ] {
            XCTAssertNil(telegramUploadMedia(typed, webPPreview: invalid, resourceID: 801))
        }
        let native = try XCTUnwrap(telegramUploadMedia(typed, webPPreview: preview, resourceID: 801)?.1.media as? TelegramMediaFile)
        XCTAssertEqual(native.previewRepresentations.count, 1)
        XCTAssertEqual((native.previewRepresentations.first?.resource as? LocalFileMediaResource)?.fileId, 900)
        let optional = try XCTUnwrap(telegramUploadMedia(typed, resourceID: 801)?.1.media as? TelegramMediaFile)
        XCTAssertTrue(optional.previewRepresentations.isEmpty)
    }

    // Catches missing transport JPEG, replacement of the original, and wrong native preview geometry/flags.
    func testTypedWebPPreparationStoresSeparateFirstFrameJPEGAndOriginalBytes() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: [.file], grouped: false, webP: true)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let (resources, preparations) = try await prepare(box, draft: draft, items: items)
        defer { preparations.forEach { $0.stop() } }
        let file = try XCTUnwrap(resources[0].reference?.media as? TelegramMediaFile)
        XCTAssertEqual(file.previewRepresentations.count, 1)
        guard let preview = file.previewRepresentations.first else { return }
        XCTAssertEqual(preview.dimensions, PixelDimensions(width: 320, height: 160))
        XCTAssertTrue(preview.progressiveSizes.isEmpty); XCTAssertNil(preview.immediateThumbnailData)
        XCTAssertFalse(preview.hasVideo); XCTAssertFalse(preview.isPersonal); XCTAssertEqual(preview.typeHint, .generic)
        let previewResource = try XCTUnwrap(preview.resource as? LocalFileMediaResource)
        XCTAssertNotEqual(previewResource.fileId, resources[0].resourceID); XCTAssertFalse(previewResource.isSecretRelated)
        let previewData = try await value(box.mediaBox.resourceData(previewResource, pathExtension: nil,
            option: .complete(waitUntilFetchStatus: false)))
        XCTAssertTrue(previewData.complete)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: previewData.path))
        XCTAssertGreaterThan(bytes.count, 0); XCTAssertLessThanOrEqual(bytes.count, 1_048_576)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg"); XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 320); XCTAssertEqual(image.height, 160)
        let original = try await value(box.mediaBox.resourceData(file.resource, pathExtension: nil,
            option: .complete(waitUntilFetchStatus: false)))
        XCTAssertTrue(original.complete)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: original.path)), UploadWebPFixture.staticLossless.data)
        XCTAssertEqual(try Data(contentsOf: items[0].file.url), UploadWebPFixture.staticLossless.data)
        XCTAssertEqual(file.mimeType, "image/webp")
    }

    // Native representation equality omits hidden flags; the complete receipt must check this derivative explicitly.
    func testWebPPreviewHiddenFlagsCannotAcknowledgeNativeQueue() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: [.file], grouped: false, webP: true)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let (resources, preparations) = try await prepare(box, draft: draft, items: items)
        defer { preparations.forEach { $0.stop() } }
        let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), resources: resources, groupKeys: [])
        var messages = try XCTUnwrap(receipt.messages(replySource: nil))
        let file = try XCTUnwrap(resources[0].reference?.media as? TelegramMediaFile)
        guard let preview = file.previewRepresentations.first else { return XCTFail("WebP transport preview missing") }
        let mutations = [
            TelegramMediaImageRepresentation(dimensions: preview.dimensions, resource: preview.resource,
                progressiveSizes: [1], immediateThumbnailData: nil),
            TelegramMediaImageRepresentation(dimensions: preview.dimensions, resource: preview.resource,
                progressiveSizes: [], immediateThumbnailData: Data([7])),
            TelegramMediaImageRepresentation(dimensions: preview.dimensions, resource: preview.resource,
                progressiveSizes: [], immediateThumbnailData: nil, hasVideo: true),
            TelegramMediaImageRepresentation(dimensions: preview.dimensions, resource: preview.resource,
                progressiveSizes: [], immediateThumbnailData: nil, isPersonal: true),
            TelegramMediaImageRepresentation(dimensions: preview.dimensions, resource: preview.resource,
                progressiveSizes: [], immediateThumbnailData: nil, typeHint: .video)
        ]
        for altered in mutations {
            messages[0] = batchNativeReplacingMedia(messages[0], file.withUpdatedPreviewRepresentations([altered]))
            let result = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages))
            XCTAssertFalse(result.1)
            let saved = try await value(batchNativeRead(box, ids: result.0.compactMap { $0 }))
            XCTAssertEqual(saved.0, draft)
        }
    }

    // Catches acknowledging a real queued WebP whose sticker attributes differ from the frozen resource.
    func testMissingExtraOrReorderedWebPAttributesCannotAcknowledgeNativeQueue() async throws {
        let mutations: [([TelegramMediaFileAttribute]) -> [TelegramMediaFileAttribute]] = [
            { Array($0.reversed()) }, { Array($0.dropLast()) }, { $0 + [.Animated] }
        ]
        for mutate in mutations {
            let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
            let (draft, items) = try await fixture(root, modes: [.file], grouped: false, webP: true)
            defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
            let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
            let (resources, preparations) = try await prepare(box, draft: draft, items: items)
            defer { preparations.forEach { $0.stop() } }
            let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
                target: .init(accountID: 1, chatID: 42, title: "Synthetic"), resources: resources, groupKeys: [])
            var messages = try XCTUnwrap(receipt.messages(replySource: nil))
            let file = try XCTUnwrap(resources[0].reference?.media as? TelegramMediaFile)
            XCTAssertEqual(file.attributes, [.ImageSize(size: PixelDimensions(width: 320, height: 160)),
                .FileName(fileName: "item-0.txt"), .Sticker(displayText: "", packReference: nil, maskData: nil)])
            messages[0] = batchNativeReplacingMedia(messages[0], file.withUpdatedAttributes(mutate(file.attributes)))
            let result = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages))
            XCTAssertFalse(result.1)
            let saved = try await value(batchNativeRead(box, ids: result.0.compactMap { $0 }))
            XCTAssertEqual(saved.0, draft)
        }
    }

    func testSyntheticAccountSentinelIsNotConvertedToNativePeerID() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: [.file, .file], grouped: true, accountID: -1)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let seeded = try await value(batchNativeSeedPointerOnly(box, draft: draft)); XCTAssertTrue(seeded)
        let accepted = expectation(description: "Synthetic native queue accepted whole set")
        var ids: [TelegramUploadQueueID] = []
        let provider = TelegramSyntheticUploadProvider(postbox: box)
        let lease = provider.submit(items: items, draft: draft,
            target: .init(accountID: -1, chatID: 42, title: "Synthetic")) { event in
                if case let .accepted(values) = event { ids = values; accepted.fulfill() }
            }
        defer { lease.stop() }
        await fulfillment(of: [accepted], timeout: 20)
        XCTAssertEqual(ids.count, 2)
        let store = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: -1),
            files: { throw TelegramUploadFileError.unavailable })
        let saved = try await store.load(chatID: 42)
        XCTAssertEqual(saved?.accountID, -1, "The native author fixture must not change Makosh's scoped account identity")
        XCTAssertEqual(saved?.disposition, .acceptedBatch(messageIDs: ids))
    }
    private weak var previousBox: Postbox?

    func testTwentyOneDocumentsEnterNativeCoreWithThreeGroupsAndOneAtomicCompleteReceiptAfterReopen() async throws {
        let root = try root(), path = root.appendingPathComponent("postbox")
        let (draft, items) = try await fixture(root, modes: Array(repeating: .file, count: 21), grouped: true)
        defer { for item in items { try? TelegramUploadFileIO.discard(item.file) } }
        var ids: [MessageId] = []
        do {
            let box = try await open(path); previousBox = box
            let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
            let (resources, preparations) = try await prepare(box, draft: draft, items: items)
            defer { preparations.forEach { $0.stop() } }
            let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
                target: .init(accountID: 1, chatID: 42, title: "Synthetic"), resources: resources, groupKeys: [111, 222, 333])
            let messages = try XCTUnwrap(receipt.messages(replySource: nil))
            let admitted = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages))
            XCTAssertTrue(admitted.1); ids = admitted.0.compactMap { $0 }; XCTAssertEqual(ids.count, 21)
            let (saved, queued) = try await value(batchNativeRead(box, ids: ids))
            XCTAssertEqual(saved?.disposition, .acceptedBatch(messageIDs: ids.map(TelegramUploadQueueID.init)))
            XCTAssertEqual(saved?.items, draft.items)
            XCTAssertEqual(queued.map(\.groupingKey), Array(repeating: 111, count: 10) + Array(repeating: 222, count: 10) + [333])
            for (index, message) in queued.enumerated() {
                XCTAssertEqual(message.text, [9, 19, 20].contains(index) ? "Batch 😀" : "")
                XCTAssertEqual((message.attributes.first { $0 is TextEntitiesMessageAttribute } as? TextEntitiesMessageAttribute)?.entities ?? [],
                    [9, 19, 20].contains(index) ? [MessageTextEntity(range: 0..<5, type: .Bold)] : [])
                XCTAssertEqual(message.author?.id, PeerId(1)); XCTAssertTrue(message.flags.contains(.Unsent))
                let media = try XCTUnwrap(message.media.first as? TelegramMediaFile)
                XCTAssertEqual((media.resource as? LocalFileMediaResource)?.fileId, resources[index].resourceID)
                let cached = try await value(box.mediaBox.resourceData(media.resource, pathExtension: nil, option: .complete(waitUntilFetchStatus: false)))
                XCTAssertTrue(cached.complete)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cached.path)), Data("Payload \(index)".utf8))
            }
            let again = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages))
            XCTAssertTrue(again.0.isEmpty); XCTAssertFalse(again.1)
        }
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let reopened = try await open(path)
        let retained = try await value(batchNativeRead(reopened, ids: ids))
        XCTAssertEqual(retained.0?.items, draft.items)
        XCTAssertEqual(retained.0?.disposition, .acceptedBatch(messageIDs: ids.map(TelegramUploadQueueID.init)))
        XCTAssertEqual(retained.1.count, 21)
    }

    func testSeparateDocumentsQueueLeadingRichTextAndRejectPartialAcknowledgement() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: [.file, .file], grouped: false)
        defer { for item in items { try? TelegramUploadFileIO.discard(item.file) } }
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let (resources, preparations) = try await prepare(box, draft: draft, items: items)
        defer { preparations.forEach { $0.stop() } }
        let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), resources: resources, groupKeys: [])
        let messages = try XCTUnwrap(receipt.messages(replySource: nil))
        let result = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages, dropLastACK: true))
        XCTAssertEqual(result.0.count, 3); XCTAssertFalse(result.1)
        let (saved, queued) = try await value(batchNativeRead(box, ids: result.0.compactMap { $0 }))
        XCTAssertEqual(saved, draft, "A partial receipt cannot mark any subset accepted")
        XCTAssertEqual(queued.map(\.text), ["Batch 😀", "", ""])
        XCTAssertEqual(queued.map { $0.media.count }, [0, 1, 1]); XCTAssertTrue(queued.allSatisfy { $0.groupingKey == nil })
    }

    func testLaterResourceOrGroupingMismatchCannotProduceAcceptedPointer() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: [.photo, .video], grouped: true)
        defer { for item in items { try? TelegramUploadFileIO.discard(item.file) } }
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let (resources, preparations) = try await prepare(box, draft: draft, items: items)
        defer { preparations.forEach { $0.stop() } }
        let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), resources: resources, groupKeys: [111])
        var messages = try XCTUnwrap(receipt.messages(replySource: nil))
        messages[1] = messages[1].withUpdatedGroupingKey { _ in nil }
        let result = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages))
        XCTAssertFalse(result.1)
        let saved = try await value(batchNativeRead(box, ids: result.0.compactMap { $0 }))
        XCTAssertEqual(saved.0, draft)
        XCTAssertNotNil(resources[1].videoCover); XCTAssertNotNil(resources[1].videoThumbnail)
        XCTAssertThrowsError(try TelegramUploadBatchEnqueueReceipt(draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), resources: Array(resources.reversed()), groupKeys: [111]))
    }

    func testBatchSubmissionPreparesAllResourcesAndQueuesEveryMessageThroughNativeCore() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: Array(repeating: .file, count: 11), grouped: true)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let done = expectation(description: "Whole batch accepted")
        var events: [TelegramUploadBatchEvent] = []
        let lease = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: items, draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"),
            enqueue: { receipt, messages in telegramUploadBatchEnqueueLocally(postbox: box, receipt: receipt, messages: messages) },
            receive: { event in events.append(event); if case .accepted = event { done.fulfill() } })
        defer { lease.stop() }
        await fulfillment(of: [done], timeout: 20)
        guard case let .accepted(ids) = events.last else { return XCTFail("Missing complete acceptance") }
        XCTAssertEqual(ids.count, 11); XCTAssertEqual(events.first, .committing)
        let saved = try await value(batchNativeRead(box, ids: ids.map(\.nativeID)))
        XCTAssertEqual(saved.0?.disposition, .acceptedBatch(messageIDs: ids))
        XCTAssertEqual(saved.1.map(\.text), Array(repeating: "", count: 9) + ["Batch 😀", "Batch 😀"])
        XCTAssertEqual(saved.1[0].groupingKey, saved.1[9].groupingKey)
        XCTAssertNotEqual(saved.1[9].groupingKey, saved.1[10].groupingKey)
    }

    func testForeignCloudReferenceOnLaterVideoCoverCannotAcknowledgeLocalBatch() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: [.photo, .video], grouped: true)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let (resources, preparations) = try await prepare(box, draft: draft, items: items)
        defer { preparations.forEach { $0.stop() } }
        let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), resources: resources, groupKeys: [111])
        var messages = try XCTUnwrap(receipt.messages(replySource: nil))
        guard case let .message(text, attributes, stickers, reference, thread, reply, story, key, correlation, bubbles) = messages[1],
              let video = reference?.media as? TelegramMediaFile, let cover = video.videoCover else { return XCTFail("Missing covered video") }
        let changed = TelegramMediaImage(imageId: cover.imageId, representations: cover.representations,
            immediateThumbnailData: nil, reference: .cloud(imageId: 99, accessHash: 88, fileReference: nil),
            partialReference: nil, flags: [])
        messages[1] = .message(text: text, attributes: attributes, inlineStickers: stickers,
            mediaReference: .standalone(media: video.withUpdatedVideoCover(changed)), threadId: thread,
            replyToMessageId: reply, replyToStoryId: story, localGroupingKey: key, correlationId: correlation,
            bubbleUpEmojiOrStickersets: bubbles)
        let result = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages))
        XCTAssertFalse(result.1)
        let saved = try await value(batchNativeRead(box, ids: result.0.compactMap { $0 })); XCTAssertEqual(saved.0, draft)
    }

    func testStoppingAtCommitBoundaryQueuesNoSubsetAndPreservesStartedPreparation() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: [.file, .file], grouped: true)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let committing = expectation(description: "Stop before native enqueue")
        var lease: TelegramUploadBatchSubmission?
        lease = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: items, draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"),
            enqueue: { receipt, messages in telegramUploadBatchEnqueueLocally(postbox: box, receipt: receipt, messages: messages) },
            receive: { event in
                if event == .committing { lease?.stop(); committing.fulfill() }
                else { XCTFail("A stopped submission cannot emit \(event)") }
            })
        defer { lease?.stop(); lease = nil }
        await fulfillment(of: [committing], timeout: 20)
        let saved = try await value(batchNativeRead(box, ids: [])); XCTAssertEqual(saved.0, draft)
        let queued = try await value(box.unsentMessageIdsView() |> take(1)); XCTAssertTrue(queued.ids.isEmpty)
    }

    func testHiddenRepresentationFlagsOnLaterPhotoOrVideoCannotAcknowledgeBatch() async throws {
        for mode in [TelegramUploadMode.photo, .video] {
            let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
            let (draft, items) = try await fixture(root, modes: [.photo, mode], grouped: true)
            defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
            let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
            let (resources, preparations) = try await prepare(box, draft: draft, items: items)
            defer { preparations.forEach { $0.stop() } }
            let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
                target: .init(accountID: 1, chatID: 42, title: "Synthetic"), resources: resources, groupKeys: [111])
            var messages = try XCTUnwrap(receipt.messages(replySource: nil))
            let media = try XCTUnwrap(resources[1].reference?.media)
            let representation: TelegramMediaImageRepresentation
            if let image = media as? TelegramMediaImage { representation = try XCTUnwrap(image.representations.first) }
            else { representation = try XCTUnwrap((media as? TelegramMediaFile)?.previewRepresentations.first) }
            let changed = TelegramMediaImageRepresentation(dimensions: representation.dimensions, resource: representation.resource,
                progressiveSizes: [1], immediateThumbnailData: Data([7]), hasVideo: true, isPersonal: true, typeHint: .video)
            if let image = media as? TelegramMediaImage {
                messages[1] = batchNativeReplacingMedia(messages[1], TelegramMediaImage(imageId: image.imageId,
                    representations: [changed], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: []))
            } else {
                messages[1] = batchNativeReplacingMedia(messages[1], try XCTUnwrap(media as? TelegramMediaFile).withUpdatedPreviewRepresentations([changed]))
            }
            let result = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages))
            XCTAssertFalse(result.1, "Hidden derivative metadata changed for \(mode)")
            let saved = try await value(batchNativeRead(box, ids: result.0.compactMap { $0 })); XCTAssertEqual(saved.0, draft)
        }
    }

    func testMixedPhotoAndCoveredVideoSubmissionRetainsCaptionSpoilerAndEveryDerivative() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (original, items) = try await fixture(root, modes: [.photo, .video], grouped: true)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let draft = original.updating(captionInput: original.captionInput, captionAboveMedia: true, mediaSpoiler: true, disposition: .submissionStarted)
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let accepted = expectation(description: "Mixed visual batch accepted")
        var ids: [TelegramUploadQueueID] = []
        let lease = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: items, draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"),
            enqueue: { receipt, messages in telegramUploadBatchEnqueueLocally(postbox: box, receipt: receipt, messages: messages) },
            receive: { if case let .accepted(values) = $0 { ids = values; accepted.fulfill() } })
        defer { lease.stop() }
        await fulfillment(of: [accepted], timeout: 20)
        let saved = try await value(batchNativeRead(box, ids: ids.map(\.nativeID)))
        XCTAssertEqual(saved.0?.disposition, .acceptedBatch(messageIDs: ids)); XCTAssertEqual(saved.1.count, 2)
        XCTAssertEqual(saved.1.map(\.text), ["Batch 😀", ""])
        for message in saved.1 {
            XCTAssertEqual(message.attributes.filter { $0 is MediaSpoilerMessageAttribute }.count, 1)
            XCTAssertEqual(message.attributes.filter { $0 is InvertMediaMessageAttribute }.count, 1)
        }
        let video = try XCTUnwrap(saved.1.last?.media.first as? TelegramMediaFile)
        let cover = try XCTUnwrap(video.videoCover?.representations.first?.resource)
        let thumbnail = try XCTUnwrap(video.previewRepresentations.first?.resource)
        let cachedCover = try await value(box.mediaBox.resourceData(cover, pathExtension: nil, option: .complete(waitUntilFetchStatus: false)))
        XCTAssertTrue(cachedCover.complete)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cachedCover.path)), try Data(contentsOf: XCTUnwrap(items[1].file.videoCover?.url)))
        let cachedThumbnail = try await value(box.mediaBox.resourceData(thumbnail, pathExtension: nil, option: .complete(waitUntilFetchStatus: false)))
        XCTAssertTrue(cachedThumbnail.complete); XCTAssertGreaterThan(cachedThumbnail.size, 0)
    }

    func testChangedLastPayloadRejectsWholeSubmissionBeforeCommitting() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: [.file, .file], grouped: true)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        try Data("Changed 1".utf8).write(to: items[1].file.url)
        let rejected = expectation(description: "Changed later file rejected")
        var events: [TelegramUploadBatchEvent] = []
        let lease = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: items, draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"),
            enqueue: { receipt, messages in telegramUploadBatchEnqueueLocally(postbox: box, receipt: receipt, messages: messages) },
            receive: { events.append($0); if $0 == .rejected { rejected.fulfill() } })
        defer { lease.stop() }
        await fulfillment(of: [rejected], timeout: 20)
        XCTAssertEqual(events, [.rejected])
        let saved = try await value(batchNativeRead(box, ids: [])); XCTAssertEqual(saved.0, draft)
        let queued = try await value(box.unsentMessageIdsView() |> take(1))
        XCTAssertTrue(queued.ids.isEmpty)
    }

    func testLostBatchAcknowledgementRetainsCompleteReceiptAndRejectsResubmission() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (draft, items) = try await fixture(root, modes: [.file, .file], grouped: false)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let uncertain = expectation(description: "Acknowledgement lost after commit")
        let lease = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: items, draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), enqueue: { receipt, messages in
                telegramUploadBatchEnqueueLocally(postbox: box, receipt: receipt, messages: messages, loseAcknowledgement: true)
            }, receive: { if $0 == .uncertain { uncertain.fulfill() } })
        defer { lease.stop() }
        await fulfillment(of: [uncertain], timeout: 20)
        let saved = try await value(batchNativeRead(box, ids: []))
        guard case let .acceptedBatch(ids) = saved.0?.disposition else { return XCTFail("Lost callback cannot erase durable receipt") }
        XCTAssertEqual(ids.count, 3)
        let rejected = expectation(description: "Old snapshot cannot send again")
        let retry = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: items, draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"),
            enqueue: { receipt, messages in telegramUploadBatchEnqueueLocally(postbox: box, receipt: receipt, messages: messages) },
            receive: { if $0 == .rejected { rejected.fulfill() } })
        defer { retry.stop() }
        await fulfillment(of: [rejected], timeout: 20)
        let queued = try await value(box.unsentMessageIdsView() |> take(1))
        XCTAssertEqual(queued.ids.count, 3)
    }

    func testUnsupportedPeerNamespaceRejectsBeforePreparingOrCommittingBatch() async throws {
        for namespace in [Namespaces.Peer.SecretChat, Namespaces.Peer.Empty] {
            let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
            let chatID = PeerId(namespace: namespace, id: ._internalFromInt64Value(42)).toInt64()
            let (draft, items) = try await fixture(root, modes: [.file, .file], grouped: true, chatID: chatID)
            defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
            let target = TelegramUploadTarget(accountID: 1, chatID: chatID, title: "Synthetic")
            let (resources, preparations) = try await prepare(box, draft: draft, items: items)
            defer { preparations.forEach { $0.stop() } }
            XCTAssertThrowsError(try TelegramUploadBatchEnqueueReceipt(draft: draft, target: target, resources: resources, groupKeys: [111]))
            let rejected = expectation(description: "Unsupported peer rejected before commit")
            var events: [TelegramUploadBatchEvent] = []
            let lease = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: items, draft: draft, target: target,
                enqueue: { receipt, messages in telegramUploadBatchEnqueueLocally(postbox: box, receipt: receipt, messages: messages) },
                receive: { events.append($0); if $0 == .rejected { rejected.fulfill() } })
            defer { lease.stop() }
            await fulfillment(of: [rejected], timeout: 20)
            XCTAssertEqual(events, [.rejected])
        }
    }

    func testCanonicalReplyThreadAcceptedButInjectedQuoteOrTodoCannotAcknowledgeBatch() async throws {
        for mutation in ["canonical", "quote", "todo", "thread"] {
            let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
            let (original, items) = try await fixture(root, modes: [.file, .file], grouped: true)
            defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
            let sourceValue = try await value(batchNativeReplySource(box))
            let source = try XCTUnwrap(sourceValue); XCTAssertTrue(source.canReply)
            let draft = try TelegramPendingUploadDraft(id: original.id, accountID: 1, chatID: 42, title: "Synthetic",
                captionInput: original.captionInput, originalDraft: nil, replyTarget: .init(source: source),
                items: original.items, isGrouped: true, disposition: .submissionStarted)
            let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
            let (resources, preparations) = try await prepare(box, draft: draft, items: items)
            defer { preparations.forEach { $0.stop() } }
            let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
                target: .init(accountID: 1, chatID: 42, title: "Synthetic", replySource: source), resources: resources, groupKeys: [111])
            var messages = try XCTUnwrap(receipt.messages(replySource: source))
            if mutation == "quote" || mutation == "todo" {
                messages[1] = messages[1].withUpdatedReplyToMessageId(.init(messageId:
                    MessageId(peerId: PeerId(42), namespace: Namespaces.Message.Cloud, id: 7),
                    quote: mutation == "quote" ? .init(text: "Injected quote", offset: nil, entities: [], media: nil) : nil,
                    todoItemId: mutation == "todo" ? 99 : nil))
            }
            let result = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages, rewriteReplyThread: mutation == "thread"))
            XCTAssertEqual(result.1, mutation == "canonical", mutation)
            let saved = try await value(batchNativeRead(box, ids: result.0.compactMap { $0 }))
            if mutation == "canonical" {
                XCTAssertEqual(saved.0?.disposition, .acceptedBatch(messageIDs: result.0.compactMap { $0 }.map(TelegramUploadQueueID.init)))
                for message in saved.1 {
                    let reply = try XCTUnwrap(message.attributes.first { $0 is ReplyMessageAttribute } as? ReplyMessageAttribute)
                    XCTAssertEqual(reply.threadMessageId, MessageId(peerId: PeerId(42), namespace: Namespaces.Message.Cloud, id: 77))
                    XCTAssertNil(reply.quote); XCTAssertNil(reply.todoItemId); XCTAssertFalse(reply.isQuote)
                }
            } else { XCTAssertEqual(saved.0, draft) }
        }
    }

    func testForgedReplyThreadWithOriginalFingerprintRejectsBeforeNativeQueueInsertion() async throws {
        let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
        let (original, items) = try await fixture(root, modes: [.file, .file], grouped: true)
        defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let sourceValue = try await value(batchNativeReplySource(box))
        let fresh = try XCTUnwrap(sourceValue), metadata = fresh.metadata
        let source = TelegramMessageActionSource(metadata: .init(peerID: metadata.peerID,
            namespace: metadata.namespace, messageID: metadata.messageID, fingerprint: metadata.fingerprint,
            text: metadata.text, authorID: metadata.authorID, canReply: true, canEdit: false,
            canForward: false, canDeleteLocally: false, canDeleteForEveryone: false, threadID: 999),
            accountID: 1, chatID: 42)
        let draft = try TelegramPendingUploadDraft(id: original.id, accountID: 1, chatID: 42, title: "Synthetic",
            captionInput: original.captionInput, originalDraft: nil, replyTarget: .init(source: source),
            items: original.items, isGrouped: true, disposition: .submissionStarted)
        let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let (resources, preparations) = try await prepare(box, draft: draft, items: items)
        defer { preparations.forEach { $0.stop() } }
        let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic", replySource: source), resources: resources, groupKeys: [111])
        let messages = try XCTUnwrap(receipt.messages(replySource: source))
        let result = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages))
        XCTAssertTrue(result.0.isEmpty)
        XCTAssertFalse(result.1)
        let saved = try await value(batchNativeRead(box, ids: result.0.compactMap { $0 }))
        XCTAssertEqual(saved.0, draft)
        XCTAssertTrue(saved.1.isEmpty)
    }

    func testMigratedReplyAcceptsNativeQuoteWithLastEligibleMediaOrNoMedia() async throws {
        for mediaCount in [0, 2] {
            let root = try root(), box = try await open(root.appendingPathComponent("postbox"))
            let targetID = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(42))
            let (original, items) = try await fixture(root, modes: [.file, .file], grouped: true, chatID: targetID.toInt64())
            defer { items.forEach { try? TelegramUploadFileIO.discard($0.file) } }
            let (resources, preparations) = try await prepare(box, draft: original, items: items)
            defer { preparations.forEach { $0.stop() } }
            let media: [Media] = (0..<mediaCount).map { index in
                let id = Int64(901 + index)
                return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil,
                    resource: CloudDocumentMediaResource(datacenterId: 1, fileId: id, accessHash: 7, size: 9,
                        fileReference: Data([7]), fileName: "Synthetic quote \(index).txt"),
                    previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil,
                    mimeType: "text/plain", size: 9, attributes: [.FileName(fileName: "Synthetic quote \(index).txt")],
                    alternativeRepresentations: [])
            }
            let sourceValue = try await value(batchNativeMigratedReplySource(box, targetID: targetID, media: media))
            let source = try XCTUnwrap(sourceValue); XCTAssertTrue(source.canReply)
            let draft = try TelegramPendingUploadDraft(id: original.id, accountID: 1, chatID: targetID.toInt64(), title: "Synthetic",
                captionInput: original.captionInput, originalDraft: nil, replyTarget: .init(source: source),
                items: original.items, isGrouped: true, disposition: .submissionStarted)
            let seeded = try await value(batchNativeSeed(box, draft: draft)); XCTAssertTrue(seeded)
            let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft,
                target: .init(accountID: 1, chatID: targetID.toInt64(), title: "Synthetic", replySource: source), resources: resources, groupKeys: [111])
            let messages = try XCTUnwrap(receipt.messages(replySource: source))
            let result = try await value(batchNativeEnqueue(box, receipt: receipt, messages: messages))
            XCTAssertEqual(result.0.count, 2); XCTAssertTrue(result.1, "media count: \(mediaCount)")
            let saved = try await value(batchNativeRead(box, ids: result.0.compactMap { $0 }, chatID: targetID.toInt64()))
            XCTAssertEqual(saved.0?.disposition, .acceptedBatch(messageIDs: result.0.compactMap { $0 }.map(TelegramUploadQueueID.init)))
            for queued in saved.1 {
                let reply = try XCTUnwrap(queued.attributes.first { $0 is ReplyMessageAttribute } as? ReplyMessageAttribute)
                let quote = try XCTUnwrap(reply.quote); XCTAssertFalse(reply.isQuote)
                XCTAssertEqual(quote.text, "Synthetic migrated reply")
                if mediaCount == 0 { XCTAssertNil(quote.media) }
                else {
                    let file = try XCTUnwrap(quote.media as? TelegramMediaFile)
                    XCTAssertEqual(file.fileId, MediaId(namespace: Namespaces.Media.CloudFile, id: 902))
                }
            }
        }
    }

    private func fixture(_ root: URL, modes: [TelegramUploadMode], grouped: Bool, chatID: Int64 = 42, accountID: Int64 = 1, webP: Bool = false) async throws -> (TelegramPendingUploadDraft, [TelegramUploadBatchItem]) {
        let preparationID = UUID()
        var items: [TelegramUploadBatchItem] = [], stored: [TelegramPendingUploadItem] = []
        for (index, mode) in modes.enumerated() {
            let source = root.appendingPathComponent("item-\(index)." + (mode == .file ? "txt" : mode == .photo ? "jpg" : "mov"))
            switch mode {
            case .file:
                if webP { try writeUploadWebPFixture(source) }
                else { try Data("Payload \(index)".utf8).write(to: source) }
            case .photo: try writeUploadVideoCoverFixture(source)
            case .video: try await writeUploadVideoFixture(source)
            }
            var file = try await TelegramUploadFileIO.stage(source, mode: mode)
            if webP {
                file = .init(id: file.id, name: file.name, size: file.size, mode: .file, pixelWidth: nil,
                    pixelHeight: nil, url: file.url, directory: file.directory, metadata: .webP(.init(width: 320, height: 160)))
            }
            if mode == .video {
                let coverURL = root.appendingPathComponent("cover-\(index).jpg"); try writeUploadVideoCoverFixture(coverURL)
                let cover = try await TelegramUploadVideoCoverIO.stage(coverURL, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
                file = .init(id: file.id, name: file.name, size: file.size, mode: file.mode, pixelWidth: file.pixelWidth,
                    pixelHeight: file.pixelHeight, url: file.url, directory: file.directory, video: file.video, videoCover: cover)
            }
            let itemID = UUID(), identity = TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID)
            func record(_ url: URL, name: String, size: Int64, kind: String, attachmentID: String) throws -> ArchiveFileRecord {
                let id = UUID(), sealed = root.appendingPathComponent(id.uuidString)
                let envelope = try ArchiveFileCapture(file: url, byteCount: size).seal(to: sealed, key: Data(repeating: 7, count: 32), objectID: id)
                return ArchiveFileRecord(id: id, identity: identity, attachment: .init(id: attachmentID, kind: kind, name: name, size: size),
                    objectKey: "vaults/synthetic/files/" + id.uuidString.lowercased(), storageID: String(repeating: "a", count: 64),
                    receipt: envelope, capturedAt: Date(timeIntervalSince1970: 100), state: .stored)
            }
            let archived = try record(file.url, name: file.name, size: file.size, kind: file.mode.rawValue,
                attachmentID: TelegramPendingUploadItem.attachmentID(itemID))
            let cover = try file.videoCover.map { cover in TelegramPendingUploadVideoCover(file:
                try record(cover.url, name: cover.name, size: cover.size, kind: "photo", attachmentID: TelegramPendingUploadItem.coverAttachmentID(itemID)),
                width: cover.width, height: cover.height) }
            items.append(.init(id: itemID, file: file)); stored.append(.init(id: itemID, file: archived, video: file.video, videoCover: cover, metadata: file.metadata))
        }
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Batch 😀", entities: [.init(offset: 0, length: 5, kind: .bold)]))
        return (try TelegramPendingUploadDraft(id: preparationID, accountID: accountID, chatID: chatID, title: "Synthetic", captionInput: input,
            originalDraft: nil, replyTarget: nil, items: stored, isGrouped: grouped,
            presentation: webP ? .file : nil, disposition: .submissionStarted), items)
    }

    private func prepare(_ box: Postbox, draft: TelegramPendingUploadDraft, items: [TelegramUploadBatchItem]) async throws -> ([TelegramUploadBatchResource], [TelegramUploadMediaBoxPreparation]) {
        var resources: [TelegramUploadBatchResource] = [], leases: [TelegramUploadMediaBoxPreparation] = []
        do {
            for (index, item) in items.enumerated() {
                let ready = expectation(description: "Batch original and derivatives read back")
                var result: Result<TelegramPreparedUploadMedia, TelegramUploadFileError>?
                let lease = TelegramUploadMediaBoxPreparation(mediaBox: box.mediaBox, file: item.file,
                    expectedPlaintextSHA256: draft.items[index].file.plaintextSHA256) { result = $0; ready.fulfill() }
                leases.append(lease)
                await fulfillment(of: [ready], timeout: 20)
                resources.append(.init(item: item, plaintextSHA256: draft.items[index].file.plaintextSHA256, prepared: try XCTUnwrap(result).get()))
            }
            return (resources, leases)
        } catch { leases.forEach { $0.stop() }; throw error }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func open(_ root: URL) async throws -> Postbox {
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Encrypted batch Postbox")
        var box: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false, isReadOnly: false,
            useCopy: false, useCaches: false, removeDatabaseOnError: false) |> deliverOnMainQueue).start(next: {
                if case let .postbox(value) = $0 { box = value; opened.fulfill() }
            })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let result = try XCTUnwrap(box), ready = expectation(description: "Both MediaBox stores ready")
        ready.expectedFulfillmentCount = 2
        let a = (result.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        let b = (result.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        defer { a.dispose(); b.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return result
    }
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let ready = expectation(description: "Native batch transaction")
        var result: T?
        let operation = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; ready.fulfill() })
        defer { operation.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return try XCTUnwrap(result)
    }
}

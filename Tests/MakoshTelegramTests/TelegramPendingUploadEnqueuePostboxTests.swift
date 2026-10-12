import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func receiptSeed(_ box: Postbox, draft: TelegramPendingUploadDraft) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        if case .success = telegramPendingUploadWrite(transaction: transaction, accountID: draft.accountID, draft: draft, expectedRevision: nil) { return true }
        return false
    }
}
private func receiptValidate(_ box: Postbox, receipt: TelegramPendingUploadEnqueueReceipt) -> Signal<Bool, NoError> {
    box.transaction { receipt.validate(transaction: $0) }
}
private func receiptRaw(_ box: Postbox, account: Int64, chat: Int64, bytes: Data? = nil) -> Signal<Data?, NoError> {
    box.transaction { transaction in
        let key = telegramPendingUploadKey(accountID: account, chatID: chat)
        if let bytes { transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: bytes)) }
        return transaction.getPreferencesEntry(key: key)?.data
    }
}
private func receiptEnqueue(_ box: Postbox, receipt: TelegramPendingUploadEnqueueReceipt, id: MessageId, returnedIDs: [MessageId?]? = nil,
                            placementCount: Int = 0, spoilerCount: Int = 0, media: [Media] = []) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        guard receipt.validate(transaction: transaction) else { return false }
        let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: 100, flags: [.Unsent], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
            authorId: nil, text: receipt.caption.text,
            attributes: telegramOutgoingTextAttributes(receipt.caption) + (0..<placementCount).map { _ in InvertMediaMessageAttribute() }
                + (0..<spoilerCount).map { _ in MediaSpoilerMessageAttribute() }, media: media)
        _ = transaction.addMessages([message], location: .Random)
        return receipt.acknowledge(transaction: transaction, messageIDs: returnedIDs ?? [id])
    }
}
private func receiptRead(_ box: Postbox, account: Int64, chat: Int64, id: MessageId) -> Signal<(TelegramPendingUploadDraft?, Bool), NoError> {
    box.transaction { transaction in
        let draft = try? telegramPendingUploadRead(transaction: transaction, accountID: account, chatID: chat).get()
        return (draft ?? nil, transaction.getMessage(id) != nil)
    }
}
private func receiptBadIDs(_ box: Postbox, receipt: TelegramPendingUploadEnqueueReceipt, ids: [MessageId?]) -> Signal<Bool, NoError> {
    box.transaction { receipt.acknowledge(transaction: $0, messageIDs: ids) }
}
private func receiptMismatchedMessage(_ box: Postbox, receipt: TelegramPendingUploadEnqueueReceipt, id: MessageId, incoming: Bool, wrongText: Bool, wrongEntities: Bool) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: 100, flags: incoming ? [.Incoming] : [.Unsent], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
            authorId: nil, text: wrongText ? "different" : receipt.caption.text,
            attributes: wrongEntities ? [] : telegramOutgoingTextAttributes(receipt.caption), media: [])
        _ = transaction.addMessages([message], location: .Random)
        return receipt.acknowledge(transaction: transaction, messageIDs: [id])
    }
}
@MainActor final class TelegramPendingUploadEnqueuePostboxTests: XCTestCase {
    func testSingleFileReceiptCannotAdmitFirstItemOfBatch() async throws {
        let box = try await open(root()), original = try pendingUploadBatchFixture()
        let draft = original.updating(captionInput: original.captionInput, captionAboveMedia: false, mediaSpoiler: false,
            disposition: .submissionStarted)
        let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let single = receipt(draft)
        let admitted = try await value(receiptValidate(box, receipt: single))
        XCTAssertFalse(admitted, "A first-item receipt cannot authorize a multi-file preparation")
        let id = MessageId(peerId: PeerId(42), namespace: Namespaces.Message.Local, id: 999)
        let accepted = try await value(receiptEnqueue(box, receipt: single, id: id))
        XCTAssertFalse(accepted)
        let retained = try await value(receiptRead(box, account: 1, chat: 42, id: id))
        XCTAssertFalse(retained.1, "Batch rejection must happen before adding even the first message")
        XCTAssertEqual(retained.0, draft)
    }

    func testCoverReceiptRequiresAdmittedBytesAndCanonicalSeparateNativeImage() async throws {
        let box = try await open(root()), draft = try pendingUploadVideoCoverFixture(disposition: .submissionStarted)
        let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let saved = try XCTUnwrap(draft.videoCover)
        let cover = TelegramUploadVideoCover(id: UUID(), width: 160, height: 320, size: saved.file.plaintextByteCount,
            name: saved.file.attachment.name, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"), sha256: saved.file.plaintextSHA256)
        let file = uploadVideoMappingFixture(name: draft.file.attachment.name, size: draft.file.plaintextByteCount, videoCover: cover)
        let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 16, height: 32, size: 456)
        let descriptor = TelegramUploadVideoThumbnailResource(id: 124, width: 160, height: 320, size: cover.size)
        let (resource, reference) = try XCTUnwrap(telegramUploadMedia(file, videoThumbnail: thumbnail, videoCover: descriptor))
        let original = try XCTUnwrap(reference.media as? TelegramMediaFile)
        let receipt = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), file: file, caption: draft.captionInput.formattedText,
            localResourceID: resource.fileId, videoThumbnail: thumbnail, videoCover: descriptor)
        let missing = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"),
            file: uploadVideoMappingFixture(name: draft.file.attachment.name, size: draft.file.plaintextByteCount),
            caption: draft.captionInput.formattedText, localResourceID: resource.fileId, videoThumbnail: thumbnail)
        let admitted = try await value(receiptValidate(box, receipt: missing)); XCTAssertFalse(admitted)
        func image(_ previews: [TelegramMediaImageRepresentation], id: MediaId = MediaId(namespace: 0, id: 0),
                   immediate: Data? = nil, flags: TelegramMediaImageFlags = []) -> TelegramMediaImage {
            TelegramMediaImage(imageId: id, representations: previews, immediateThumbnailData: immediate,
                reference: nil, partialReference: nil, flags: flags)
        }
        let variants: [TelegramMediaImage?] = [nil, image([]), image([descriptor.representation, descriptor.representation]),
            image([thumbnail.representation]), image([descriptor.representation], id: MediaId(namespace: 0, id: 1)),
            image([descriptor.representation], immediate: Data([1])), image([descriptor.representation], flags: [.hasStickers]),
            image([TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 160, height: 320),
                resource: LocalFileMediaResource(fileId: 124, size: cover.size, isSecretRelated: true), progressiveSizes: [], immediateThumbnailData: nil)])]
        let id = MessageId(peerId: PeerId(42), namespace: Namespaces.Message.Local, id: 199)
        for coverImage in variants {
            let altered = TelegramMediaFile(fileId: original.fileId, partialReference: nil, resource: original.resource,
                previewRepresentations: original.previewRepresentations, videoThumbnails: [], videoCover: coverImage,
                immediateThumbnailData: nil, mimeType: original.mimeType, size: original.size, attributes: original.attributes, alternativeRepresentations: [])
            let accepted = try await value(receiptEnqueue(box, receipt: receipt, id: id, media: [altered])); XCTAssertFalse(accepted)
            let retained = try await value(receiptRead(box, account: 1, chat: 42, id: id))
            XCTAssertEqual(retained.0?.videoCover, saved); XCTAssertEqual(retained.0?.disposition, .submissionStarted)
        }
        let accepted = try await value(receiptEnqueue(box, receipt: receipt, id: id, media: [original])); XCTAssertTrue(accepted)
        let retained = try await value(receiptRead(box, account: 1, chat: 42, id: id))
        XCTAssertEqual(retained.0?.videoCover, saved)
        XCTAssertEqual(retained.0?.disposition, .accepted(localMessageID: "42:\(Namespaces.Message.Local):199"))
    }
    func testVideoReceiptRejectsMissingWrongOrDuplicateNativeMediaAndRetainsExactDescriptorAfterReopen() async throws {
        let path = try root()
        let draft = try pendingUploadVideoFixture(disposition: .submissionStarted)
        let id = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 34)
        do {
            let box = try await open(path); previousBox = box
            let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
            let file = uploadVideoMappingFixture(name: draft.file.attachment.name, size: draft.file.plaintextByteCount)
            let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 16, height: 32, size: 456)
            let (resource, reference) = try XCTUnwrap(telegramUploadMedia(file, videoThumbnail: thumbnail))
            let native = try XCTUnwrap(reference.media as? TelegramMediaFile)
            let receipt = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id,
                target: .init(accountID: 1, chatID: 42, title: "Synthetic"), file: file,
                caption: draft.captionInput.formattedText, localResourceID: resource.fileId, videoThumbnail: thumbnail)
            let valid = try await value(receiptValidate(box, receipt: receipt)); XCTAssertTrue(valid)
            // Every rejected ACK leaves the marker started, so no storage retry can resend.
            let wrongDuration = native.withUpdatedAttributes([
                .Video(duration: 1, size: PixelDimensions(width: 16, height: 32), flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil),
                .FileName(fileName: "portrait.mp4")])
            let wrongDimensions = native.withUpdatedAttributes([
                .Video(duration: 0.3333333432674408, size: PixelDimensions(width: 32, height: 16), flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil),
                .FileName(fileName: "portrait.mp4")])
            let wrongFlags = native.withUpdatedAttributes([
                .Video(duration: 0.3333333432674408, size: PixelDimensions(width: 16, height: 32), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil),
                .FileName(fileName: "portrait.mp4")])
            let wrongAnimation = native.withUpdatedAttributes(native.attributes + [.Animated])
            let anotherResource = try XCTUnwrap(telegramUploadMedia(file, videoThumbnail: thumbnail)?.1.media)
            for media in [[], [wrongDuration], [wrongDimensions], [wrongFlags], [wrongAnimation],
                          [native.withUpdatedSize(file.size + 1)], [anotherResource], [native, native]] as [[Media]] {
                let accepted = try await value(receiptEnqueue(box, receipt: receipt, id: id, media: media))
                XCTAssertFalse(accepted)
                let retained = try await value(receiptRead(box, account: 1, chat: 42, id: id))
                XCTAssertEqual(retained.0?.disposition, .submissionStarted)
            }
            let accepted = try await value(receiptEnqueue(box, receipt: receipt, id: id, media: [native]))
            XCTAssertTrue(accepted)
        }
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let reopened = try await open(path)
        let stored = try await value(receiptRead(reopened, account: 1, chat: 42, id: id))
        XCTAssertTrue(stored.1)
        XCTAssertEqual(stored.0?.video, draft.video)
        XCTAssertEqual(stored.0?.disposition, .accepted(localMessageID: "42:\(Namespaces.Message.Local):34"))
    }
    // Native representation == ignores these flags. The receipt must reject
    // every changed thumbnail, without turning an uncertain send into a retry.
    func testVideoReceiptRejectsMissingExtraChangedOrNoncanonicalThumbnail() async throws {
        let box = try await open(root()), draft = try pendingUploadVideoFixture(disposition: .submissionStarted)
        let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let file = uploadVideoMappingFixture(name: draft.file.attachment.name, size: draft.file.plaintextByteCount)
        let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 16, height: 32, size: 456)
        let (resource, reference) = try XCTUnwrap(telegramUploadMedia(file, videoThumbnail: thumbnail))
        let native = try XCTUnwrap(reference.media as? TelegramMediaFile)
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
        let receipt = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
            caption: draft.captionInput.formattedText, localResourceID: resource.fileId, videoThumbnail: thumbnail)
        let missing = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
            caption: draft.captionInput.formattedText, localResourceID: resource.fileId)
        let missingAdmission = try await value(receiptValidate(box, receipt: missing)); XCTAssertFalse(missingAdmission)
        let id = MessageId(peerId: PeerId(42), namespace: Namespaces.Message.Local, id: 35)
        func preview(resource: TelegramMediaResource = LocalFileMediaResource(fileId: 123, size: 456),
                     dimensions: PixelDimensions = PixelDimensions(width: 16, height: 32),
                     progressive: [Int32] = [], immediate: Data? = nil, video: Bool = false,
                     personal: Bool = false, type: TelegramMediaImageRepresentation.TypeHint = .generic) -> TelegramMediaImageRepresentation {
            TelegramMediaImageRepresentation(dimensions: dimensions, resource: resource, progressiveSizes: progressive,
                immediateThumbnailData: immediate, hasVideo: video, isPersonal: personal, typeHint: type)
        }
        let canonical = preview()
        let changed = [preview(resource: LocalFileMediaResource(fileId: 124, size: 456)),
            preview(resource: LocalFileMediaResource(fileId: 123, size: 455)),
            preview(resource: LocalFileMediaResource(fileId: 123, size: 456, isSecretRelated: true)),
            preview(resource: EmptyMediaResource()), preview(resource: resource),
            preview(dimensions: PixelDimensions(width: 32, height: 16)), preview(progressive: [456]),
            preview(immediate: Data([1])), preview(video: true), preview(personal: true), preview(type: .video)]
        for previews in [[], [canonical, canonical]] + changed.map({ [$0] }) {
            let accepted = try await value(receiptEnqueue(box, receipt: receipt, id: id,
                media: [native.withUpdatedPreviewRepresentations(previews)]))
            XCTAssertFalse(accepted)
            let retained = try await value(receiptRead(box, account: 1, chat: 42, id: id))
            XCTAssertEqual(retained.0?.disposition, .submissionStarted)
        }
        let accepted = try await value(receiptEnqueue(box, receipt: receipt, id: id, media: [native]))
        XCTAssertTrue(accepted)
    }
    func testNativeSpoilerMustMatchAdmissionAndReceiptSurvivesReopen() async throws {
        for spoiler in [false, true] {
            let path = try root()
            let draft = try pendingUploadMutating(pendingUploadFixture(disposition: .submissionStarted)) {
                $0["mediaSpoiler"] = spoiler; $0["captionAboveMedia"] = true
                var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
                attachment["kind"] = "photo"; file["attachment"] = attachment; $0["file"] = file
            }
            let id = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 32)
            do {
                let box = try await open(path); previousBox = box
                let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
                let file = TelegramUploadFile(id: UUID(), name: draft.file.attachment.name, size: draft.file.plaintextByteCount,
                    mode: .photo, pixelWidth: 30, pixelHeight: 60, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
                let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
                let wrong = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
                    caption: draft.captionInput.formattedText, captionAboveMedia: true, mediaSpoiler: !spoiler)
                let admitted = try await value(receiptValidate(box, receipt: wrong)); XCTAssertFalse(admitted)
                let right = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
                    caption: draft.captionInput.formattedText, captionAboveMedia: true, mediaSpoiler: spoiler)
                for count in spoiler ? [0, 2] : [1, 2] {
                    let mismatch = try await value(receiptEnqueue(box, receipt: right, id: id, placementCount: 1, spoilerCount: count))
                    XCTAssertFalse(mismatch)
                    let unchanged = try await value(receiptRead(box, account: 1, chat: 42, id: id))
                    XCTAssertEqual(unchanged.0?.disposition, .submissionStarted)
                }
                let accepted = try await value(receiptEnqueue(box, receipt: right, id: id, placementCount: 1, spoilerCount: spoiler ? 1 : 0))
                XCTAssertTrue(accepted)
            }
            for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(previousBox)
            let reopened = try await open(path)
            let stored = try await value(receiptRead(reopened, account: 1, chat: 42, id: id))
            XCTAssertTrue(stored.1); XCTAssertEqual(stored.0?.mediaSpoiler, spoiler)
            XCTAssertEqual(stored.0?.captionAboveMedia, true)
            XCTAssertEqual(stored.0?.disposition, .accepted(localMessageID: "42:\(Namespaces.Message.Local):32"))
        }
    }
    func testNativePlacementMustMatchAdmissionAndReceiptSurvivesReopen() async throws {
        let path = try root()
        let draft = try pendingUploadMutating(pendingUploadFixture(disposition: .submissionStarted)) {
            $0["captionAboveMedia"] = true
            var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
            attachment["kind"] = "photo"; file["attachment"] = attachment; $0["file"] = file
        }
        let id = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 31)
        do {
            let box = try await open(path); previousBox = box
            let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
            let file = TelegramUploadFile(id: UUID(), name: draft.file.attachment.name, size: draft.file.plaintextByteCount,
                mode: .photo, pixelWidth: 30, pixelHeight: 60, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
            let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
            let wrong = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
                caption: draft.captionInput.formattedText, captionAboveMedia: false)
            let refused = try await value(receiptEnqueue(box, receipt: wrong, id: id)); XCTAssertFalse(refused)
            let right = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file,
                caption: draft.captionInput.formattedText, captionAboveMedia: true)
            for count in [0, 2] {
                let mismatch = try await value(receiptEnqueue(box, receipt: right, id: id, placementCount: count))
                XCTAssertFalse(mismatch)
                let unchanged = try await value(receiptRead(box, account: 1, chat: 42, id: id))
                XCTAssertEqual(unchanged.0?.disposition, .submissionStarted)
            }
            let accepted = try await value(receiptEnqueue(box, receipt: right, id: id, placementCount: 1)); XCTAssertTrue(accepted)
        }
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let reopened = try await open(path)
        let stored = try await value(receiptRead(reopened, account: 1, chat: 42, id: id))
        XCTAssertTrue(stored.1); XCTAssertEqual(stored.0?.captionAboveMedia, true)
        XCTAssertEqual(stored.0?.disposition, .accepted(localMessageID: "42:\(Namespaces.Message.Local):31"))
    }
    private weak var previousBox: Postbox?
    private func open(_ root: URL) async throws -> Postbox {
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Encrypted draft fixture")
        var box: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(value) = $0 { box = value; opened.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let result = try XCTUnwrap(box)
        let ready = expectation(description: "Both MediaBox stores ready"); ready.expectedFulfillmentCount = 2
        let storage = (result.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        let cache = (result.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        defer { storage.dispose(); cache.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return result
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }


    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Receipt transaction")
        var result: T?
        let operation = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { operation.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func receipt(_ draft: TelegramPendingUploadDraft, preparation: UUID? = nil,
                         caption: TelegramFormattedText? = nil, name: String? = nil, size: Int64? = nil,
                         mode: TelegramUploadMode = .file, target: TelegramUploadTarget? = nil) -> TelegramPendingUploadEnqueueReceipt {
        .init(preparationID: preparation ?? draft.id,
            target: target ?? .init(accountID: draft.accountID, chatID: draft.chatID, title: draft.title),
            file: .init(id: UUID(), name: name ?? draft.file.attachment.name, size: size ?? draft.file.plaintextByteCount,
                mode: mode, pixelWidth: nil, pixelHeight: nil,
                url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused")),
            caption: caption ?? draft.captionInput.formattedText)
    }
    private func enqueueThenRelease(path: URL, draft: TelegramPendingUploadDraft, id: MessageId) async throws {
        let box = try await open(path); previousBox = box
        let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let accepted = try await value(receiptEnqueue(box, receipt: receipt(draft), id: id)); XCTAssertTrue(accepted)
        // Only a transaction result is observed, no upload UI/draft ACK callback.
    }
    func testAtomicReceiptSurvivesReopenBeforeUIAcknowledgementAndDuplicateDoesNotAdd() async throws {
        let path = try root(), draft = try pendingUploadFixture(disposition: .submissionStarted)
        let id = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 1)
        try await enqueueThenRelease(path: path, draft: draft, id: id)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let box = try await open(path)
        let result = try await value(receiptRead(box, account: draft.accountID, chat: draft.chatID, id: id))
        let stored = try XCTUnwrap(result.0)
        XCTAssertTrue(result.1)
        XCTAssertEqual(stored.disposition, .accepted(localMessageID: "\(draft.chatID):\(Namespaces.Message.Local):1"))
        XCTAssertNotEqual(stored.revision, draft.revision)
        XCTAssertEqual(stored.captionInput, draft.captionInput); XCTAssertEqual(stored.originalDraft, draft.originalDraft)
        XCTAssertEqual(stored.replyTarget, draft.replyTarget); XCTAssertEqual(stored.file, draft.file)
        let second = MessageId(peerId: id.peerId, namespace: id.namespace, id: 2)
        let duplicate = try await value(receiptEnqueue(box, receipt: receipt(draft), id: second)); XCTAssertFalse(duplicate)
        let absent = try await value(receiptRead(box, account: draft.accountID, chat: draft.chatID, id: second))
        XCTAssertFalse(absent.1); XCTAssertEqual(absent.0, stored)
    }
    func testOrphanIncomingAndMismatchedCaptionCannotFabricateAcceptance() async throws {
        let box = try await open(root()), draft = try pendingUploadFixture(disposition: .submissionStarted)
        let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let raw = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID))
        let orphan = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 20)
        let orphanResult = try await value(receiptBadIDs(box, receipt: receipt(draft), ids: [orphan]))
        XCTAssertFalse(orphanResult)
        let unchanged = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(unchanged, raw)
        for (offset, values) in [(true, false, false), (false, true, false), (false, false, true)].enumerated() {
            let id = MessageId(peerId: orphan.peerId, namespace: orphan.namespace, id: Int32(21 + offset))
            let result = try await value(receiptMismatchedMessage(box, receipt: receipt(draft), id: id,
                incoming: values.0, wrongText: values.1, wrongEntities: values.2))
            XCTAssertFalse(result)
            let retained = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(retained, raw)
        }
    }
    func testRefusalMatrixDoesNotEnqueueOrMutatePointer() async throws {
        let box = try await open(root()), draft = try pendingUploadFixture(disposition: .submissionStarted)
        let seeded = try await value(receiptSeed(box, draft: draft)); XCTAssertTrue(seeded)
        let raw = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID))
        let id = MessageId(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local, id: 10)
        let sameTextDifferentEntities = try TelegramFormattedText(text: draft.captionInput.formattedText.text)
        let wrongReply = TelegramMessageActionSource(metadata: .init(peerID: draft.chatID, namespace: Namespaces.Message.Cloud,
            messageID: 1, fingerprint: "synthetic", text: "target", authorID: nil, canReply: true, canEdit: false,
            canForward: false, canDeleteLocally: false, canDeleteForEveryone: false), accountID: draft.accountID, chatID: draft.chatID)
        let normalized = try TelegramFormattedText(text: draft.captionInput.formattedText.text.precomposedStringWithCanonicalMapping,
            entities: draft.captionInput.formattedText.entities)
        let attempts = [receipt(draft, preparation: UUID()), receipt(draft, caption: sameTextDifferentEntities), receipt(draft, caption: normalized),
            receipt(draft, name: "other.txt"), receipt(draft, size: draft.file.plaintextByteCount + 1), receipt(draft, mode: .photo),
            receipt(draft, target: .init(accountID: 9, chatID: draft.chatID, title: "foreign")),
            receipt(draft, target: .init(accountID: draft.accountID, chatID: 99, title: "foreign")),
            receipt(draft, target: .init(accountID: draft.accountID, chatID: draft.chatID, title: draft.title, replySource: wrongReply))]
        for attempt in attempts {
            let result = try await value(receiptEnqueue(box, receipt: attempt, id: id)); XCTAssertFalse(result)
            let bytes = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(bytes, raw)
            let state = try await value(receiptRead(box, account: draft.accountID, chat: draft.chatID, id: id)); XCTAssertFalse(state.1)
        }
        let original = try XCTUnwrap(raw)
        let cancelled = try pendingUploadMutating(draft) { $0["disposition"] = ["cancelled": [:]] }
        var cancelledBytes = Data("Makosh.PendingUpload.JSON.v1\n".utf8)
        cancelledBytes.append(try JSONEncoder().encode(cancelled))
        let foreign = try pendingUploadMutating(draft) { $0["accountID"] = 999 }
        var foreignBytes = Data("Makosh.PendingUpload.JSON.v1\n".utf8); foreignBytes.append(try JSONEncoder().encode(foreign))
        for bytes in [Data("unknown-owner".utf8), Data("Makosh.PendingUpload.JSON.v1\n{}".utf8), cancelledBytes, foreignBytes] {
            _ = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID, bytes: bytes))
            let refused = try await value(receiptEnqueue(box, receipt: receipt(draft), id: id)); XCTAssertFalse(refused)
            let retained = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(retained, bytes)
        }
        _ = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID, bytes: original))
        for ids: [MessageId?] in [[], [nil], [id, id],
            [MessageId(peerId: id.peerId, namespace: Namespaces.Message.Cloud, id: 1)],
            [MessageId(peerId: PeerId(99), namespace: Namespaces.Message.Local, id: 1)]] {
            let refused = try await value(receiptBadIDs(box, receipt: receipt(draft), ids: ids)); XCTAssertFalse(refused)
            let retained = try await value(receiptRaw(box, account: draft.accountID, chat: draft.chatID)); XCTAssertEqual(retained, original)
        }
        // No rollback promise: a malformed nonempty enqueue result leaves the
        // message present, but never fabricates an accepted receipt or retry ACK.
        let uncertain = try await value(receiptEnqueue(box, receipt: receipt(draft), id: id, returnedIDs: []))
        XCTAssertFalse(uncertain)
        let uncertainState = try await value(receiptRead(box, account: draft.accountID, chat: draft.chatID, id: id))
        XCTAssertTrue(uncertainState.1); XCTAssertEqual(uncertainState.0?.disposition, .submissionStarted)
    }
}

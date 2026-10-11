import XCTest
import Foundation
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func sourceFactsNativeUser(_ id: Int64) -> TelegramUser {
    TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil)
}

private nonisolated func sourceFactsNativeSeed(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([sourceFactsNativeUser(1), sourceFactsNativeUser(42)], update: { _, new in new })
        return true
    }
}

private nonisolated func sourceFactsNativeRead(_ box: Postbox, ids: [MessageId]) -> Signal<[Message], NoError> {
    box.transaction { transaction in ids.compactMap { transaction.getMessage($0) } }
}

private nonisolated func sourceFactsNativeEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
                                                messages: [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages, now: { 100 }) { messages, admission, commit in
        enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
            peerId: PeerId(42), messages: messages, transactionAdmission: admission, transactionCommit: commit)
    }
}

@MainActor final class TelegramSourceFactsNativeQueueTests: TelegramSourceFactsIntegrationTestCase {
    private func submit(_ fixture: SourceFactsTestArchive, box: Postbox, items: [TelegramUploadBatchItem],
                        presentation: TelegramUploadPresentation, grouped: Bool, caption: String) async throws -> (TelegramPendingUploadDraft, [Message])? {
        let store = fixture.session(box), id = UUID()
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: caption))
        do {
            try await store.prepare(preparationID: id, items: items, isGrouped: grouped, presentation: presentation,
                target: fixture.target, captionInput: input, originalDraft: nil)
        } catch { XCTFail("Source-facts native fixture must prepare: \(error)"); return nil }
        try await store.save(preparationID: id, chatID: 42, captionInput: input, disposition: .submissionStarted)
        let draft = try await sourceFactsLoad(store)
        let seeded = try await sourceFactsValue(sourceFactsNativeSeed(box))
        XCTAssertTrue(seeded)
        let done = expectation(description: "Complete source-facts local queue receipt")
        var accepted: [TelegramUploadQueueID]?
        let submission = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: items, draft: draft,
            target: fixture.target, enqueue: { receipt, messages in
                sourceFactsNativeEnqueue(box, receipt: receipt, messages: messages)
            }, receive: { event in
                switch event {
                case let .accepted(ids): accepted = ids; done.fulfill()
                case .rejected, .uncertain: XCTFail("A complete schema14 capability must enter the local native queue"); done.fulfill()
                default: break
                }
            })
        defer { submission.stop() }
        await fulfillment(of: [done], timeout: 20)
        guard let ids = accepted else { return nil }
        let saved = try await sourceFactsLoad(store)
        XCTAssertEqual(saved.disposition, .acceptedBatch(messageIDs: ids))
        XCTAssertEqual(saved.items, draft.items)
        let messages = try await sourceFactsValue(sourceFactsNativeRead(box, ids: ids.map(\.nativeID)))
        return (saved, messages)
    }

    private func cachedBytes(_ box: Postbox, resource: any MediaResource) async throws -> Data {
        let cached = try await sourceFactsValue(box.mediaBox.resourceData(resource, pathExtension: nil,
            option: .complete(waitUntilFetchStatus: false)))
        XCTAssertTrue(cached.complete); XCTAssertEqual(cached.offset, 0)
        return try Data(contentsOf: URL(fileURLWithPath: cached.path))
    }

    // Catches choosing the last file's caption merely because a grouped Media chunk starts with a skipped image.
    func testMixedMediaGroupCaptionsTheFirstActualVisualAndAcknowledgesEveryResource() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let small = try await sourceFactsSmallImage(fixture), photo = try await sourceFactsPhoto(fixture)
        let last = try await sourceFactsSmallImage(fixture, name: "last.png")
        let items = [small, photo, last]
        defer { items.forEach { try? $0.discard() } }
        guard let (saved, messages) = try await submit(fixture, box: box, items: items, presentation: .media,
            grouped: true, caption: "Caption 😀") else { return }
        XCTAssertEqual(saved.schemaVersion, 14); XCTAssertEqual(saved.items.map(\.sourceFacts), items.map(\.sourceFacts))
        XCTAssertEqual(messages.count, 3)
        guard messages.count == 3 else { return }
        XCTAssertEqual(messages.map(\.text), ["", "Caption 😀", ""])
        XCTAssertNotNil(messages[0].groupingKey); XCTAssertEqual(messages[0].groupingKey, messages[1].groupingKey)
        XCTAssertEqual(messages[0].groupingKey, messages[2].groupingKey)
        let file = try XCTUnwrap(messages[0].media.first as? TelegramMediaFile)
        let image = try XCTUnwrap(messages[1].media.first as? TelegramMediaImage)
        let lastFile = try XCTUnwrap(messages[2].media.first as? TelegramMediaFile)
        XCTAssertEqual(file.mimeType, "image/png")
        XCTAssertEqual(file.attributes, [.ImageSize(size: .init(width: 39, height: 48)), .FileName(fileName: "small.png")])
        XCTAssertEqual(lastFile.mimeType, "image/png")
        XCTAssertEqual(lastFile.attributes, [.ImageSize(size: .init(width: 39, height: 48)), .FileName(fileName: "last.png")])
        let imageResource = try XCTUnwrap(image.representations.first?.resource)
        XCTAssertEqual(Set([file.resource.id, imageResource.id, lastFile.resource.id]).count, 3)
        let firstBytes = try await cachedBytes(box, resource: file.resource)
        let photoBytes = try await cachedBytes(box, resource: imageResource)
        let lastBytes = try await cachedBytes(box, resource: lastFile.resource)
        XCTAssertEqual(firstBytes, try Data(contentsOf: small.file.url))
        XCTAssertEqual(photoBytes, try Data(contentsOf: photo.file.url))
        XCTAssertEqual(lastBytes, try Data(contentsOf: last.file.url))
        XCTAssertEqual(try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events"), [["0"]])
    }

    // Catches deriving raw File ImageSize from the normalized JPEG or dropping source facts in the projection/receipt.
    func testRawPhotoFileProjectionPreservesLogicalImageSizeFilenameAndOriginalBytes() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let photo = try await sourceFactsPhoto(fixture)
        defer { try? photo.discard() }
        guard let (saved, messages) = try await submit(fixture, box: box, items: [photo], presentation: .file,
            grouped: false, caption: "Original") else { return }
        let native = try XCTUnwrap(messages.first?.media.first as? TelegramMediaFile)
        XCTAssertEqual(native.attributes, [.ImageSize(size: .init(width: 40, height: 80)), .FileName(fileName: "photo.jpg")])
        XCTAssertEqual(native.mimeType, "image/jpeg"); XCTAssertEqual(messages.first?.text, "Original")
        let original = try XCTUnwrap(photo.originalFile)
        XCTAssertEqual(native.size, original.size)
        let bytes = try await cachedBytes(box, resource: native.resource)
        XCTAssertEqual(bytes, try Data(contentsOf: original.url))
        XCTAssertEqual(saved.items[0].sourceFacts, photo.sourceFacts)
        XCTAssertEqual(saved.items[0].sourceFacts?.role, .original)
    }

    // Catches unchecked Int32(Double) conversion for authenticated finite but unrepresentable logical dimensions.
    func testFileMapperRefusesLogicalDimensionsOutsidePositiveNativeIntegerRange() async throws {
        let fixture = try await sourceFactsArchive(), photo = try await sourceFactsPhoto(fixture)
        defer { try? photo.discard() }
        let raw = try XCTUnwrap(photo.originalFile), frozen = try XCTUnwrap(photo.sourceFacts)
        for width in [Double(Int32.max) + 1, 0.5] {
            let facts = TelegramUploadSourceFacts(itemID: frozen.itemID, role: .original, name: frozen.name,
                byteCount: frozen.byteCount, plaintextSHA256: frozen.plaintextSHA256, selectionMIME: "image/jpeg",
                image: .decoded(width: width, height: 80), grouping: .ordinary)
            XCTAssertNil(telegramUploadMedia(raw, sourceFacts: facts, resourceID: 801), "Logical dimensions must fail safely before native conversion")
        }
    }

    // Catches issuing a native capability from a correct digest but substituted decoded source facts.
    func testMediaBoxReprobesRawPhotoFactsBeforeIssuingAResource() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let photo = try await sourceFactsPhoto(fixture)
        defer { try? photo.discard() }
        let raw = try XCTUnwrap(photo.originalFile), frozen = try XCTUnwrap(photo.sourceFacts)
        let altered = TelegramUploadSourceFacts(itemID: frozen.itemID, role: frozen.role, name: frozen.name,
            byteCount: frozen.byteCount, plaintextSHA256: frozen.plaintextSHA256, selectionMIME: frozen.selectionMIME,
            image: .decoded(width: 41, height: 80), grouping: .ordinary)
        let done = expectation(description: "MediaBox refuses substituted source facts")
        var result: Result<TelegramPreparedUploadMedia, TelegramUploadFileError>?
        let preparation = TelegramUploadMediaBoxPreparation(mediaBox: box.mediaBox, file: raw, originalFile: raw,
            expectedPlaintextSHA256: frozen.plaintextSHA256, sourceFacts: altered) {
                result = $0; done.fulfill()
            }
        defer { preparation.stop() }
        await fulfillment(of: [done], timeout: 20)
        guard case .failure = try XCTUnwrap(result) else {
            return XCTFail("A correct payload digest cannot authenticate different logical source dimensions")
        }
    }

    // Catches a caller substituting validly shaped source decisions while reusing the persisted pointer and payload digest.
    func testSubstitutedSourceFactsCannotReachNativeSubmission() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let photo = try await sourceFactsPhoto(fixture)
        defer { try? photo.discard() }
        let store = fixture.session(box), id = UUID()
        do {
            try await store.prepare(preparationID: id, items: [photo], isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: .empty, originalDraft: nil)
        } catch { return XCTFail("Source facts must prepare before substitution test: \(error)") }
        try await store.save(preparationID: id, chatID: 42, captionInput: .empty, disposition: .submissionStarted)
        let draft = try await sourceFactsLoad(store), frozen = try XCTUnwrap(photo.sourceFacts)
        let altered = TelegramUploadSourceFacts(itemID: frozen.itemID, role: frozen.role, name: frozen.name,
            byteCount: frozen.byteCount, plaintextSHA256: frozen.plaintextSHA256, selectionMIME: frozen.selectionMIME,
            image: .decoded(width: 41, height: 80), grouping: .ordinary)
        let done = expectation(description: "Substituted source facts refused")
        let submission = TelegramUploadBatchSubmission(postbox: box, accountID: 1,
            items: [.init(id: photo.id, file: photo.file, originalFile: photo.originalFile, sourceFacts: altered)], draft: draft,
            target: fixture.target, enqueue: { _, _ in XCTFail("Substituted facts must fail before enqueue"); return .single(.rejected) },
            receive: { if case .rejected = $0 { done.fulfill() } })
        defer { submission.stop() }
        await fulfillment(of: [done], timeout: 20)
        let unchanged = try await sourceFactsLoad(store)
        XCTAssertEqual(unchanged, draft)
    }
}

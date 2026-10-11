import XCTest
import Foundation
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func nativeVideoPeer(_ id: PeerId) -> TelegramUser {
    TelegramUser(id: id, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil)
}

private func nativeVideoSeed(_ box: Postbox, draft: TelegramPendingUploadDraft) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        var peers = [nativeVideoPeer(PeerId(draft.chatID))]
        // -1 is a fixture-only account marker, never a protocol PeerId.
        if draft.accountID >= 0 { peers.append(nativeVideoPeer(PeerId(draft.accountID))) }
        transaction.updatePeersInternal(peers, update: { _, new in new })
        if case .success = telegramPendingUploadWrite(transaction: transaction, accountID: draft.accountID,
            draft: draft, expectedRevision: nil) { return true }
        return false
    }
}

// Both hooks execute on Postbox's queue, outside MainActor. This invokes the
// production transaction core; it never constructs StoreMessage in test code.
private func nativeVideoEnqueue(_ box: Postbox, message: EnqueueMessage,
                                receipt: TelegramPendingUploadEnqueueReceipt) -> Signal<([MessageId?], Bool), NoError> {
    let accepted = Atomic<Bool>(value: false)
    return enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(receipt.target.accountID),
        isSupportUser: false, timestamp: 100, peerId: PeerId(receipt.target.chatID), messages: [message],
        transactionAdmission: { receipt.validate(transaction: $0) },
        transactionCommit: { transaction, ids in
            _ = accepted.swap(receipt.acknowledge(transaction: transaction, messageIDs: ids))
        }) |> map { ($0, accepted.with { $0 }) }
}

private func nativeVideoRead(_ box: Postbox, id: MessageId, accountID: Int64) -> Signal<(TelegramPendingUploadDraft?, Message?), NoError> {
    box.transaction { transaction in
        let draft = try? telegramPendingUploadRead(transaction: transaction, accountID: accountID,
            chatID: id.peerId.toInt64()).get()
        return (draft ?? nil, transaction.getMessage(id))
    }
}

@MainActor
final class TelegramNativeVideoEnqueueTests: XCTestCase {
    // Missing shared native construction, dropped media/options or an admission
    // bypass would break this real encrypted Postbox/MediaBox/reopen regression.
    func testOriginalVideosPassSharedNativeEnqueueAndAtomicReceiptWithoutAccountOrNetwork() async throws {
        for name in ["portrait.mp4", "portrait.mov"] {
            let root = try root()
            let source = root.appendingPathComponent(name)
            try await writeUploadVideoFixture(source, rotated: true, timescale: 30)
            let original = try Data(contentsOf: source)
            let file = try await TelegramUploadFileIO.stage(source, mode: .video)
            defer { try? TelegramUploadFileIO.discard(file) }
            let preparationID = UUID(), objectID = UUID()
            let capture = try ArchiveFileCapture(file: file.url, byteCount: file.size)
            let envelope = try capture.seal(to: root.appendingPathComponent("sealed"), key: Data(repeating: 7, count: 32), objectID: objectID)
            let record = ArchiveFileRecord(id: objectID,
                identity: TelegramPendingUploadDraft.archiveIdentity(accountID: 1, chatID: 42, preparationID: preparationID),
                attachment: .init(id: "prepared", kind: "video", name: file.name, size: file.size),
                objectKey: "vaults/synthetic/files/" + objectID.uuidString.lowercased(), storageID: String(repeating: "a", count: 64),
                receipt: envelope, capturedAt: Date(timeIntervalSince1970: 100), state: .stored)
            let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Video 😀",
                entities: [.init(offset: 0, length: 5, kind: .bold)]), selection: .init(location: 8, length: 0))
            let draft = TelegramPendingUploadDraft(id: preparationID, accountID: 1, chatID: 42, title: "Synthetic",
                captionInput: input, captionAboveMedia: true, mediaSpoiler: true, originalDraft: nil, replyTarget: nil,
                file: record, video: file.video, disposition: .submissionStarted)
            XCTAssertTrue(draft.isValid)
            var queuedID: MessageId?
            do {
                let box = try await open(root.appendingPathComponent("postbox")); previousBox = box
                let seeded = try await value(nativeVideoSeed(box, draft: draft)); XCTAssertTrue(seeded)
                let (resource, reference) = try XCTUnwrap(telegramUploadMedia(file))
                let keep = box.mediaBox.keepResource(id: resource.id).start()
                defer { keep.dispose() }
                box.mediaBox.copyResourceData(resource.id, fromTempPath: file.url.path)
                let cached = try await value(box.mediaBox.resourceData(resource, pathExtension: nil,
                    option: .complete(waitUntilFetchStatus: false)))
                XCTAssertTrue(cached.complete); XCTAssertEqual(cached.offset, 0); XCTAssertEqual(cached.size, file.size)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cached.path)), original)
                let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
                let message = try XCTUnwrap(telegramUploadMessage(caption: input.formattedText, reference: reference,
                    target: target, replySource: nil, captionAboveMedia: true, mediaSpoiler: true))
                let receipt = TelegramPendingUploadEnqueueReceipt(preparationID: preparationID, target: target, file: file,
                    caption: input.formattedText, captionAboveMedia: true, mediaSpoiler: true, localResourceID: resource.fileId)
                let result = try await value(nativeVideoEnqueue(box, message: message, receipt: receipt))
                XCTAssertEqual(result.0.count, 1); XCTAssertTrue(result.1)
                let id = try XCTUnwrap(result.0.first ?? nil); queuedID = id
                XCTAssertEqual(id.peerId, PeerId(42)); XCTAssertEqual(id.namespace, Namespaces.Message.Local)
                let state = try await value(nativeVideoRead(box, id: id, accountID: 1))
                XCTAssertEqual(state.0?.disposition, .accepted(localMessageID: "42:\(id.namespace):\(id.id)"))
                XCTAssertEqual(state.0?.video, file.video)
                let queued = try XCTUnwrap(state.1)
                XCTAssertEqual(queued.text, "Video 😀"); XCTAssertEqual(queued.author?.id, PeerId(1)); XCTAssertNil(queued.groupingKey)
                XCTAssertTrue(queued.flags.contains(.Unsent))
                let media = try XCTUnwrap(queued.media.first as? TelegramMediaFile)
                XCTAssertEqual(queued.media.count, 1); XCTAssertEqual(media.mimeType, "video/mp4"); XCTAssertEqual(media.size, file.size)
                XCTAssertEqual((media.resource as? LocalFileMediaResource)?.fileId, resource.fileId)
                XCTAssertEqual(media.attributes, [
                    .Video(duration: 0.3333333432674408, size: PixelDimensions(width: 16, height: 32),
                        flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil),
                    .FileName(fileName: "portrait.mp4")
                ] + (name.hasSuffix("mov") ? [.hintFileIsLarge] : []))
                XCTAssertEqual(queued.attributes.filter { $0 is InvertMediaMessageAttribute }.count, 1)
                XCTAssertEqual(queued.attributes.filter { $0 is MediaSpoilerMessageAttribute }.count, 1)
                XCTAssertEqual((queued.attributes.first { $0 is TextEntitiesMessageAttribute } as? TextEntitiesMessageAttribute)?.entities,
                    [MessageTextEntity(range: 0..<5, type: .Bold)])
                let second = try await value(nativeVideoEnqueue(box, message: message, receipt: receipt))
                XCTAssertTrue(second.0.isEmpty); XCTAssertFalse(second.1, "Accepted preparation cannot enter native queue twice")
            }
            for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(previousBox)
            let reopened = try await open(root.appendingPathComponent("postbox"))
            let id = try XCTUnwrap(queuedID)
            let retained = try await value(nativeVideoRead(reopened, id: id, accountID: 1))
            XCTAssertEqual(retained.0?.video, file.video)
            XCTAssertEqual(retained.0?.disposition, .accepted(localMessageID: "42:\(id.namespace):\(id.id)"))
            XCTAssertNotNil(retained.1)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    // The UI's explicit synthetic provider must preserve video options and
    // acknowledge the exact resource, rather than reject or leave uncertainty.
    func testSyntheticVideoQueueAcknowledgesExactResourceWithAndWithoutSpoiler() async throws {
        for spoiler in [false, true] {
            let root = try root()
            let source = root.appendingPathComponent("synthetic.mov")
            try await writeUploadVideoFixture(source)
            let file = try await TelegramUploadFileIO.stage(source, mode: .video)
            defer { try? TelegramUploadFileIO.discard(file) }
            let preparationID = UUID(), objectID = UUID()
            let envelope = try ArchiveFileCapture(file: file.url, byteCount: file.size).seal(
                to: root.appendingPathComponent("sealed"), key: Data(repeating: 7, count: 32), objectID: objectID)
            let record = ArchiveFileRecord(id: objectID,
                identity: TelegramPendingUploadDraft.archiveIdentity(accountID: -1, chatID: 42, preparationID: preparationID),
                attachment: .init(id: "prepared", kind: "video", name: file.name, size: file.size),
                objectKey: "vaults/synthetic/files/" + objectID.uuidString.lowercased(), storageID: String(repeating: "a", count: 64),
                receipt: envelope, capturedAt: Date(timeIntervalSince1970: 100), state: .stored)
            let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Synthetic video"))
            let draft = TelegramPendingUploadDraft(id: preparationID, accountID: -1, chatID: 42, title: "Synthetic",
                captionInput: input, captionAboveMedia: spoiler, mediaSpoiler: spoiler, originalDraft: nil, replyTarget: nil,
                file: record, video: file.video, disposition: .submissionStarted)
            let box = try await open(root.appendingPathComponent("postbox"))
            let seeded = try await value(nativeVideoSeed(box, draft: draft)); XCTAssertTrue(seeded)
            let provider = TelegramSyntheticUploadProvider(postbox: box)
            let finished = expectation(description: "Synthetic video admission")
            var event: TelegramUploadEvent?
            let lease = provider.submit(file: file, target: .init(accountID: -1, chatID: 42, title: "Synthetic"),
                preparationID: preparationID, caption: input.formattedText, captionAboveMedia: spoiler, mediaSpoiler: spoiler) {
                    switch $0 {
                    case .accepted, .rejected, .uncertain: event = $0; finished.fulfill()
                    default: break
                    }
                }
            defer { lease.stop() }
            await fulfillment(of: [finished], timeout: 5)
            guard case let .accepted(id) = event else { XCTFail("Synthetic video was not acknowledged: \(String(describing: event))"); continue }
            let parts = id.split(separator: ":").compactMap { Int32($0) }
            let messageID = MessageId(peerId: PeerId(42), namespace: try XCTUnwrap(parts.dropFirst().first), id: try XCTUnwrap(parts.last))
            let retained = try await value(nativeVideoRead(box, id: messageID, accountID: -1))
            XCTAssertEqual(retained.0?.disposition, .accepted(localMessageID: id))
            XCTAssertEqual(retained.0?.mediaSpoiler, spoiler)
            XCTAssertEqual(retained.1?.text, "Synthetic video")
            XCTAssertEqual(retained.1?.attributes.filter { $0 is MediaSpoilerMessageAttribute }.count, spoiler ? 1 : 0)
            XCTAssertEqual(retained.1?.attributes.filter { $0 is InvertMediaMessageAttribute }.count, spoiler ? 1 : 0)
        }
    }
    private weak var previousBox: Postbox?
    private func open(_ root: URL) async throws -> Postbox {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
}

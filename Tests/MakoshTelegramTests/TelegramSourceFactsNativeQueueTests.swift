import XCTest
import Foundation
import CoreGraphics
import ImageIO
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

@MainActor private final class SourceFactsPickerProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Picker preparation must not submit"); receive(.rejected); return SourceFactsPickerLease()
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
                captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Picker preparation must not submit"); receive(.rejected); return SourceFactsPickerLease()
    }
}
@MainActor private final class SourceFactsPickerLease: TelegramUploadLease { func stop() {} }

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

private nonisolated func sourceFactsNativeInstall(_ box: Postbox, draft: TelegramPendingUploadDraft, revision: UUID)
    -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    box.transaction { telegramPendingUploadWrite(transaction: $0, accountID: 1, draft: draft, expectedRevision: revision) }
}

private nonisolated func sourceFactsNativeEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
                                                messages: [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages, now: { 100 }) { messages, admission, commit in
        enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
            peerId: PeerId(42), messages: messages, transactionAdmission: admission, transactionCommit: commit)
    }
}

@MainActor final class TelegramSourceFactsNativeQueueTests: TelegramSourceFactsIntegrationTestCase {
    // Catches dropping WebP originals during photo normalization or reinterpreting frozen derivatives on restore.
    func testSelectedWebPPhotoAndFileModesRestoreAndQueueUnderBothStoragePolicies() async throws {
        for enabled in [false, true] {
            for presentation in [TelegramUploadPresentation.media, .file] {
                let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
                let source = fixture.root.appendingPathComponent("selected.jpg")
                let other = fixture.root.appendingPathComponent("other.png")
                try writeUploadWebPFixture(source); try writeUploadVideoCoverFixture(other)
                let rawBytes = try Data(contentsOf: source)
                let controller = TelegramUploadController(); controller.bind(provider: SourceFactsPickerProvider())
                defer { controller.clear() }
                controller.prepare(sources: [source, other].map { .init(source: $0, mode: .photo) }, isGrouped: true,
                    target: fixture.target, captionInput: .empty)
                for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(controller.phase, .ready); XCTAssertTrue(controller.isGrouped)
                let items = controller.items
                guard items.count == 2, items[0].file.mode == .photo else {
                    XCTFail("Selected JPEG MIME must produce a grouped photo from bounded WebP bytes"); continue
                }
                let jpegBytes = try Data(contentsOf: items[0].file.url), store = fixture.session(box), id = UUID()
                let input = try TelegramComposerInput(formattedText: .init(text: "WebP 😀"))
                try await store.prepare(preparationID: id, items: items, isGrouped: true, presentation: presentation,
                    target: fixture.target, captionInput: input, originalDraft: nil)
                let prepared = try await sourceFactsLoad(store)
                controller.clear(); try FileManager.default.removeItem(at: source); try FileManager.default.removeItem(at: other)
                let restored = try await fixture.session(box).restoreItems(draft: prepared)
                defer { restored.forEach { try? $0.discard() } }
                XCTAssertEqual(restored.map(\.id), items.map(\.id))
                XCTAssertEqual(try Data(contentsOf: restored[0].file.url), jpegBytes)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored[0].originalFile).url), rawBytes)
                guard let (accepted, messages) = try await submit(fixture, box: box, items: restored,
                    presentation: presentation, grouped: true, caption: "WebP 😀", existingPreparationID: id) else { continue }
                XCTAssertEqual(accepted.items, prepared.items); XCTAssertEqual(messages.count, 2)
                XCTAssertNotNil(messages.first?.groupingKey)
                XCTAssertEqual(messages.first?.groupingKey, messages.last?.groupingKey)
                if presentation == .media {
                    let image = try XCTUnwrap(messages[0].media.first as? TelegramMediaImage)
                    let representation = try XCTUnwrap(image.representations.first)
                    XCTAssertEqual(representation.dimensions.width, 320); XCTAssertEqual(representation.dimensions.height, 160)
                    let cached = try await cachedBytes(box, resource: representation.resource)
                    XCTAssertEqual(cached, jpegBytes); XCTAssertEqual(messages[0].text, "WebP 😀")
                } else {
                    let document = try XCTUnwrap(messages[0].media.first as? TelegramMediaFile)
                    XCTAssertEqual(document.mimeType, "image/jpeg")
                    XCTAssertFalse(document.attributes.contains { if case .Sticker = $0 { true } else { false } })
                    let cached = try await cachedBytes(box, resource: document.resource)
                    XCTAssertEqual(cached, rawBytes); XCTAssertEqual(messages[1].text, "WebP 😀")
                }
                let records = prepared.items.flatMap { [$0.file] + ($0.originalFile.map { [$0] } ?? []) }
                XCTAssertEqual(records.count, 4)
                for record in records {
                    let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                    XCTAssertEqual(object != nil, enabled)
                }
                if !enabled {
                    XCTAssertEqual(try fixture.localRecords().count, 4)
                    try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                    let resumed = try await fixture.archive.resume(); XCTAssertEqual(resumed, 0)
                    for record in records {
                        let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                        XCTAssertNil(object)
                    }
                }
            }
        }
    }

    // Catches losing the selected photo recipe during durable restore/native mapping, or creating S3 copies with OFF.
    func testSelectedPhotoSizeKeepsItsPreparedBytesThroughRestoreAndNativeQueueUnderBothPolicies() async throws {
        for enabled in [false, true] {
            for (size, width, height) in [(TelegramUploadPhotoSize.standard, Int32(1280), Int32(640)), (.large, 2560, 1280)] {
                let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
                let source = fixture.root.appendingPathComponent("photo-size.png")
                let context = try XCTUnwrap(CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                let originalBytes = try Data(contentsOf: source)
                let controller = TelegramUploadController(); controller.bind(provider: SourceFactsPickerProvider())
                defer { controller.clear() }
                controller.prepare(sources: [.init(source: source, mode: .photo)], isGrouped: false,
                    target: fixture.target, captionInput: .empty, photoSize: size)
                for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(controller.phase, .ready)
                let items = controller.items, item = try XCTUnwrap(items.first)
                XCTAssertEqual(item.file.pixelWidth, width); XCTAssertEqual(item.file.pixelHeight, height)
                XCTAssertEqual(item.sourceFacts?.image, .decoded(width: 3000, height: 1500))
                let preparedBytes = try Data(contentsOf: item.file.url), store = fixture.session(box), id = UUID()
                let input = try TelegramComposerInput(formattedText: .init(text: "Photo size 😀"))
                try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .media,
                    target: fixture.target, captionInput: input, originalDraft: nil)
                let prepared = try await sourceFactsLoad(store)
                try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .media,
                    target: fixture.target, captionInput: input, originalDraft: nil)
                let retried = try await sourceFactsLoad(store); XCTAssertEqual(retried.items, prepared.items)
                for (from, to) in [(TelegramUploadPresentation.media, TelegramUploadPresentation.file), (.file, .media)] {
                    try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id),
                        previousPresentation: from, previousGrouping: false, presentation: to, isGrouped: false, target: fixture.target)
                }
                let modeChanged = try await sourceFactsLoad(store)
                XCTAssertEqual(modeChanged.items, prepared.items); XCTAssertEqual(modeChanged.presentation, .media)
                controller.clear(); try FileManager.default.removeItem(at: source)
                let restored = try await fixture.session(box).restoreItems(draft: prepared)
                defer { restored.forEach { try? $0.discard() } }
                XCTAssertEqual(restored.map(\.id), items.map(\.id))
                XCTAssertEqual(restored.first?.file.pixelWidth, width); XCTAssertEqual(restored.first?.file.pixelHeight, height)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.first).file.url), preparedBytes)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.first?.originalFile).url), originalBytes)
                guard let (saved, messages) = try await submit(fixture, box: box, items: restored, presentation: .media,
                    grouped: false, caption: "Photo size 😀", existingPreparationID: id) else { continue }
                XCTAssertEqual(saved.items, prepared.items); XCTAssertEqual(messages.count, 1)
                XCTAssertEqual(messages.first?.text, "Photo size 😀")
                let image = try XCTUnwrap(messages.first?.media.first as? TelegramMediaImage)
                let representation = try XCTUnwrap(image.representations.first)
                XCTAssertEqual(representation.dimensions.width, width); XCTAssertEqual(representation.dimensions.height, height)
                let cached = try await cachedBytes(box, resource: representation.resource)
                XCTAssertEqual(cached, preparedBytes)
                let records = [prepared.items[0].file, try XCTUnwrap(prepared.items[0].originalFile)]
                for record in records {
                    let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                    XCTAssertEqual(object != nil, enabled)
                }
                if !enabled {
                    XCTAssertEqual(try fixture.localRecords().count, 2)
                    try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                    let resumed = try await fixture.archive.resume(); XCTAssertEqual(resumed, 0)
                    for record in records {
                        let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                        XCTAssertNil(object)
                    }
                    XCTAssertEqual(try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events"), [["0"]])
                }
            }
        }
    }

    private func lowDPIItems(_ fixture: SourceFactsTestArchive) async throws -> [TelegramUploadBatchItem] {
        let sources = try ["first.png", "second.png"].map { name in
            let url = fixture.root.appendingPathComponent(name)
            let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyDPIWidth: 36, kCGImagePropertyDPIHeight: 36] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
        }
        let controller = TelegramUploadController(); controller.bind(provider: SourceFactsPickerProvider())
        controller.prepare(sources: sources.map { .init(source: $0, mode: .photo) }, isGrouped: true,
            target: fixture.target, captionInput: .empty)
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready); XCTAssertEqual(controller.presentation, .media)
        XCTAssertTrue(controller.isGrouped); XCTAssertEqual(controller.items.map(\.file.mode), [.file, .file])
        let items = controller.items
        // The returned copies own these stages; clearing the picker must not discard them here.
        controller.discard = { _ in }; controller.clear()
        return items
    }

    // Catches losing all-document Media at capture/restore/CAS/native admission, or making new S3 copies during retries.
    func testVersionedAllDocumentMediaRestoresAndQueuesOriginalBytesUnderBothStoragePolicies() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let items = try await lowDPIItems(fixture), bytes = try items.map { try Data(contentsOf: $0.file.url) }
            defer { items.forEach { try? $0.discard() } }
            let store = fixture.session(box), id = UUID(), input = try TelegramComposerInput(formattedText: .init(text: "Source 😀"))
            do {
                try await store.prepare(preparationID: id, items: items, isGrouped: true, presentation: .media,
                    target: fixture.target, captionInput: input, originalDraft: nil)
            } catch { XCTFail("Source-selected Media must persist even with only document payloads: \(error)"); continue }
            let initial = try await sourceFactsLoad(store)
            XCTAssertEqual(initial.schemaVersion, 17); XCTAssertTrue(initial.isValid)
            XCTAssertEqual(initial.items.map(\.sourceFacts), items.map(\.sourceFacts))
            XCTAssertEqual(initial.items.map { $0.file.attachment.kind }, ["file", "file"])
            XCTAssertTrue(initial.items.allSatisfy { $0.originalFile == nil })
            try await store.prepare(preparationID: id, items: items, isGrouped: true, presentation: .media,
                target: fixture.target, captionInput: input, originalDraft: nil)
            let retried = try await sourceFactsLoad(store); XCTAssertEqual(retried.items, initial.items)
            let ids = items.map(\.id)
            for (from, to) in [(TelegramUploadPresentation.media, TelegramUploadPresentation.file), (.file, .media)] {
                try await store.updatePresentation(preparationID: id, orderedIDs: ids, previousPresentation: from,
                    previousGrouping: true, presentation: to, isGrouped: true, target: fixture.target)
            }
            for source in ["first.png", "second.png"] { try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(source)) }
            let frozen = try await sourceFactsLoad(store), restored = try await fixture.session(box).restoreItems(draft: frozen)
            let controller = TelegramUploadController()
            controller.bind(provider: SourceFactsPickerProvider(), recoveryStore: store, requiresRecovery: true)
            defer { controller.clear() }
            let restoredUpload1 = await controller.restore(draft: frozen, items: restored, target: fixture.target,
                restorationEpoch: controller.recoveryRestoreEpoch)
            XCTAssertTrue(restoredUpload1)
            XCTAssertEqual(controller.presentation, .media); XCTAssertTrue(controller.canSwitchPresentation)
            XCTAssertTrue(controller.canGroupItems); XCTAssertTrue(controller.isGrouped)
            XCTAssertFalse(controller.canUseMediaOptions); XCTAssertFalse(controller.isVisualMedia)
            XCTAssertEqual(controller.captionInput, input)
            guard let (saved, messages) = try await submit(fixture, box: box, items: restored, presentation: .media,
                grouped: true, caption: "Source 😀", existingPreparationID: id) else { continue }
            XCTAssertEqual(saved.schemaVersion, 17); XCTAssertEqual(saved.items, initial.items)
            XCTAssertEqual(messages.map(\.text), ["", "Source 😀"])
            XCTAssertNotNil(messages.first?.groupingKey); XCTAssertEqual(messages.first?.groupingKey, messages.last?.groupingKey)
            for (index, message) in messages.enumerated() {
                let file = try XCTUnwrap(message.media.first as? TelegramMediaFile)
                let cached = try await cachedBytes(box, resource: file.resource)
                XCTAssertEqual(cached, bytes[index])
            }
            for record in initial.items.map(\.file) {
                let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                XCTAssertEqual(object != nil, enabled)
            }
            if !enabled {
                XCTAssertEqual(try fixture.localRecords().count, 2)
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                let resumed = try await fixture.archive.resume(); XCTAssertEqual(resumed, 0)
                XCTAssertEqual(try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events"), [["0"]])
            }
        }
    }

    // Catches downgrading the source policy when installing/caching/removing a ZIP or removing the last other item.
    func testVersionedAllDocumentMediaKeepsItsPolicyThroughArchiveAndRemoval() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let items = try await lowDPIItems(fixture)
        defer { items.forEach { try? $0.discard() } }
        let store = fixture.session(box), id = UUID(), ids = items.map(\.id)
        try await store.prepare(preparationID: id, items: items, isGrouped: true, presentation: .media,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        let initial = try await sourceFactsLoad(store)
        try await store.updatePresentation(preparationID: id, orderedIDs: ids, previousPresentation: .media,
            previousGrouping: true, presentation: .archive, isGrouped: false, target: fixture.target)
        let archived = try await sourceFactsLoad(store)
        XCTAssertEqual(archived.schemaVersion, 18); XCTAssertNotNil(archived.archive)
        let bundle = try await store.restoreBundle(draft: archived); defer { try? bundle.discard() }
        XCTAssertEqual(bundle.items.map(\.id), ids); XCTAssertNotNil(bundle.archive)
        let copies = try fixture.localRecords(); XCTAssertEqual(copies.count, 3)
        try await store.updatePresentation(preparationID: id, orderedIDs: ids, previousPresentation: .archive,
            previousGrouping: false, presentation: .media, isGrouped: true, target: fixture.target)
        let media = try await sourceFactsLoad(store)
        XCTAssertEqual(media.schemaVersion, 18); XCTAssertEqual(media.items, initial.items)
        XCTAssertEqual(media.archive, archived.archive)
        try await store.updateItems(preparationID: id, previousIDs: ids, previousGrouping: true,
            previousPresentation: .media, orderedIDs: [ids[1]], isGrouped: false, presentation: .media, target: fixture.target)
        let removed = try await sourceFactsLoad(store)
        XCTAssertEqual(removed.schemaVersion, 17); XCTAssertEqual(removed.presentation, .media)
        XCTAssertNil(removed.archive); XCTAssertEqual(removed.items, [initial.items[1]])
        XCTAssertEqual(try fixture.localRecords(), copies, "Removing a cached descriptor retains encrypted resources")
        for record in initial.items.map(\.file) + [try XCTUnwrap(archived.archive?.file)] {
            let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
            XCTAssertNil(object)
        }
    }

    // Catches silently upgrading a frozen schema15 File preparation during retry, edit or controller restoration.
    func testOldAllDocumentFilePreparationRetainsItsMediaRestriction() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let items = try await lowDPIItems(fixture)
        defer { items.forEach { try? $0.discard() } }
        let store = fixture.session(box), id = UUID(), ids = items.map(\.id)
        try await store.prepare(preparationID: id, items: items, isGrouped: true, presentation: .file,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        let captured = try await sourceFactsLoad(store)
        let legacy = try TelegramPendingUploadDraft(id: id, accountID: 1, chatID: 42, title: captured.title,
            captionInput: .empty, originalDraft: nil, replyTarget: nil,
            items: captured.items, isGrouped: true, presentation: .file)
        XCTAssertEqual(legacy.schemaVersion, 15)
        let seeded = try await sourceFactsValue(sourceFactsNativeInstall(box, draft: legacy, revision: captured.revision))
        try seeded.get()
        try await store.prepare(preparationID: id, items: items, isGrouped: true, presentation: .file,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        let retried = try await sourceFactsLoad(store); XCTAssertEqual(retried.schemaVersion, 15)
        do {
            try await store.updatePresentation(preparationID: id, orderedIDs: ids, previousPresentation: .file,
                previousGrouping: true, presentation: .media, isGrouped: true, target: fixture.target)
            XCTFail("Existing all-document File must not acquire the newer Media allowance")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .incompatibleData) }
        try await store.updateItems(preparationID: id, previousIDs: ids, previousGrouping: true, previousPresentation: .file,
            orderedIDs: [ids[1]], isGrouped: false, presentation: .file, target: fixture.target)
        let removed = try await sourceFactsLoad(store); XCTAssertEqual(removed.schemaVersion, 15)
        let restored = try await store.restoreItems(draft: removed), controller = TelegramUploadController()
        controller.bind(provider: SourceFactsPickerProvider(), recoveryStore: store, requiresRecovery: true)
        defer { controller.clear() }
        let restoredUpload2 = await controller.restore(draft: removed, items: restored, target: fixture.target,
            restorationEpoch: controller.recoveryRestoreEpoch)
        XCTAssertTrue(restoredUpload2)
        XCTAssertEqual(controller.presentation, .file); XCTAssertFalse(controller.canSwitchPresentation)
        XCTAssertEqual(try fixture.localRecords().count, 2)
    }

    private func submit(_ fixture: SourceFactsTestArchive, box: Postbox, items: [TelegramUploadBatchItem],
                        presentation: TelegramUploadPresentation, grouped: Bool, caption: String,
                        existingPreparationID: UUID? = nil) async throws -> (TelegramPendingUploadDraft, [Message])? {
        let store = fixture.session(box), id = existingPreparationID ?? UUID()
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: caption))
        if existingPreparationID == nil {
            do {
                try await store.prepare(preparationID: id, items: items, isGrouped: grouped, presentation: presentation,
                    target: fixture.target, captionInput: input, originalDraft: nil)
            } catch { XCTFail("Source-facts native fixture must prepare: \(error)"); return nil }
        }
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

    // Catches losing new narrow-photo/raw pairs on restore, reclassifying them from logical facts, or bypassing OFF during capture/queue.
    func testNewNarrowPhotoPairsRestoreAndEnterNativeQueueUnderBothStoragePolicies() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let oldFile = try await sourceFactsSmallImage(fixture), oldPhoto = try await sourceFactsPhoto(fixture)
            defer { try? oldFile.discard(); try? oldPhoto.discard() }
            let sources = [fixture.root.appendingPathComponent("small.png"), fixture.root.appendingPathComponent("photo.jpg")]
            let rawBytes = try sources.map { try Data(contentsOf: $0) }
            let controller = TelegramUploadController(); controller.bind(provider: SourceFactsPickerProvider())
            defer { controller.clear() }
            controller.prepare(sources: sources.map { .init(source: $0, mode: .photo) }, isGrouped: true,
                target: fixture.target, captionInput: .empty)
            for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(controller.phase, .ready); XCTAssertEqual(controller.presentation, .media)
            XCTAssertEqual(controller.items.map(\.file.mode), [.photo, .photo])
            XCTAssertEqual(controller.items.map { $0.sourceFacts?.role }, [.original, .original])
            XCTAssertEqual(controller.items.first?.sourceFacts?.image, .decoded(width: 39, height: 48))
            let items = controller.items, facts = items.map(\.sourceFacts), ids = items.map(\.id)
            let photoBytes = try items.map { try Data(contentsOf: $0.file.url) }
            let store = fixture.session(box), id = UUID()
            let input = try TelegramComposerInput(formattedText: .init(text: "Pixels 😀"))
            try await store.prepare(preparationID: id, items: items, isGrouped: true, presentation: .media,
                target: fixture.target, captionInput: input, originalDraft: nil)
            let prepared = try await sourceFactsLoad(store)
            XCTAssertEqual(prepared.schemaVersion, 17)
            XCTAssertEqual(prepared.items.map { $0.file.attachment.kind }, ["photo", "photo"])
            let records = prepared.items.flatMap { [$0.file] + ($0.originalFile.map { [$0] } ?? []) }
            XCTAssertEqual(records.count, 4)
            try await store.prepare(preparationID: id, items: items, isGrouped: true, presentation: .media,
                target: fixture.target, captionInput: input, originalDraft: nil)
            let retried = try await sourceFactsLoad(store)
            XCTAssertEqual(retried.id, prepared.id); XCTAssertEqual(retried.items, prepared.items)
            XCTAssertEqual(retried.captionInput, prepared.captionInput)
            controller.clear()
            for source in sources { try FileManager.default.removeItem(at: source) }
            if !enabled {
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                let resumed = try await fixture.archive.resume(); XCTAssertEqual(resumed, 0)
            }
            let restored = try await fixture.session(box).restoreItems(draft: prepared)
            defer { restored.forEach { try? $0.discard() } }
            XCTAssertEqual(restored.map(\.id), ids); XCTAssertEqual(restored.map(\.sourceFacts), facts)
            XCTAssertEqual(try restored.map { try Data(contentsOf: $0.file.url) }, photoBytes)
            XCTAssertEqual(try restored.map { try Data(contentsOf: XCTUnwrap($0.originalFile).url) }, rawBytes)
            guard let (saved, messages) = try await submit(fixture, box: box, items: restored, presentation: .media,
                grouped: true, caption: "Pixels 😀", existingPreparationID: id) else { continue }
            XCTAssertEqual(saved.items, prepared.items); XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages.map(\.text), ["Pixels 😀", ""])
            for (index, message) in messages.enumerated() {
                let image = try XCTUnwrap(message.media.first as? TelegramMediaImage)
                let representation = try XCTUnwrap(image.representations.first)
                XCTAssertEqual(representation.dimensions.width, index == 0 ? 39 : 40)
                XCTAssertEqual(representation.dimensions.height, index == 0 ? 48 : 80)
                let bytes = try await cachedBytes(box, resource: representation.resource)
                XCTAssertEqual(bytes, photoBytes[index])
            }
            for record in records {
                let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                XCTAssertEqual(object != nil, enabled)
            }
            if !enabled {
                XCTAssertEqual(try fixture.localRecords().count, 4)
                XCTAssertEqual(try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events"), [["0"]])
            }
        }
    }

    // Legacy frozen File payloads must keep their kinds even though the current picker would prepare this narrow image as a photo.
    // Catches choosing the last file's caption merely because a grouped Media chunk starts with a skipped image.
    func testMixedMediaGroupCaptionsTheFirstActualVisualAndAcknowledgesEveryResource() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let small = try await sourceFactsSmallImage(fixture), photo = try await sourceFactsPhoto(fixture)
        let last = try await sourceFactsSmallImage(fixture, name: "last.png")
        let items = [small, photo, last]
        defer { items.forEach { try? $0.discard() } }
        guard let (saved, messages) = try await submit(fixture, box: box, items: items, presentation: .media,
            grouped: true, caption: "Caption 😀") else { return }
        XCTAssertEqual(saved.schemaVersion, 17); XCTAssertEqual(saved.items.map(\.sourceFacts), items.map(\.sourceFacts))
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

import Foundation
import XCTest
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

// Postbox transaction bodies run on its queue, outside the test's MainActor.
private func recordedVoicePeers(_ box: Postbox) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peers = [Int64(1), 42].map { value in
            TelegramUser(id: PeerId(value), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
                photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
                nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
                subscriberCount: nil, verificationIconFileId: nil)
        }
        transaction.updatePeersInternal(peers, update: { _, new in new })
    }
}
private func recordedVoiceMessage(_ box: Postbox, id: MessageId) -> Signal<Message?, NoError> {
    box.transaction { $0.getMessage(id) }
}

@MainActor private final class RecordedVoiceLocalQueueProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    private let postbox: Postbox
    private(set) var submissions = 0
    init(postbox: Postbox) { self.postbox = postbox }
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        submissions += 1
        return TelegramUploadBatchSubmission(postbox: postbox, accountID: accountID, items: items, draft: draft, target: target,
            enqueue: { [postbox] receipt, messages in
                telegramUploadBatchEnqueueLocally(postbox: postbox, receipt: receipt, messages: messages)
            }, receive: receive)
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID,
                caption: TelegramFormattedText, captionAboveMedia: Bool, mediaSpoiler: Bool,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Recorded voice must use a complete typed batch receipt")
        receive(.rejected); return RecordedVoiceUnusedLease()
    }
}
@MainActor private final class RecordedVoiceUnusedLease: TelegramUploadLease { func stop() {} }

@MainActor final class TelegramRecordedVoicePendingTests: XCTestCase {
    func testLocalVoiceRestoresAndQueuesAfterEncryptedPostboxReopen() async throws {
        try await reopenAndQueue(s3Enabled: false)
    }

    func testS3VoiceRestoresAndQueuesAfterEncryptedPostboxReopen() async throws {
        try await reopenAndQueue(s3Enabled: true)
    }

    func testControllerQueuesRecordedPCMWithS3Disabled() async throws {
        try await controllerQueue(s3Enabled: false)
    }

    func testControllerQueuesRecordedPCMWithS3Enabled() async throws {
        try await controllerQueue(s3Enabled: true)
    }

    // Exercises the real controller, encrypted recovery, native MediaBox and
    // transactional queue. The provider replaces only the unavailable server.
    private func controllerQueue(s3Enabled: Bool) async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let archiveRoot = try root(), path = try root()
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: archiveRoot.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x68, count: 32) })
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "1", conversationID: "42", messageID: "synthetic-policy")
        try await archive.setConversationFileSavingEnabled(identity: identity, enabled: s3Enabled)
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic controller voice")
        var waveform = Data(repeating: 0, count: 63); waveform[0] = 0x0c
        var accepted: TelegramPendingUploadDraft?
        do {
            let box = try await open(path); previousBox = box
            let seeded = expectation(description: "Controller voice synthetic peers")
            let seed = (recordedVoicePeers(box) |> deliverOnMainQueue).start(next: { _ in seeded.fulfill() })
            defer { seed.dispose() }; await fulfillment(of: [seeded], timeout: 20)
            let store = session(box, archive: archive), controller = TelegramUploadController()
            let provider = RecordedVoiceLocalQueueProvider(postbox: box)
            controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
            defer { controller.bind(provider: nil) }
            var pcm = [Int16](repeating: 0, count: 48_137)
            for index in 0..<100 { pcm[index] = 1_000 }
            XCTAssertTrue(controller.prepareRecordedVoice(samples: pcm, target: target))
            for _ in 0..<1_000 where !controller.canSend && controller.phase != .failed {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(controller.canSend); XCTAssertEqual(controller.phase, .ready)
            let stage = try XCTUnwrap(controller.file), bytes = try Data(contentsOf: stage.url)
            let loaded = try await store.load(chatID: 42), prepared = try XCTUnwrap(loaded)
            XCTAssertEqual(prepared.schemaVersion, 11); XCTAssertEqual(prepared.disposition, .prepared)
            XCTAssertEqual(prepared.items.count, 1); XCTAssertEqual(prepared.items[0].metadata?.voice?.waveform, waveform)
            XCTAssertEqual(prepared.items[0].file.state, s3Enabled ? .stored : .local)
            XCTAssertEqual(controller.preparationContextID, prepared.id)
            controller.send(contextID: UUID())
            XCTAssertEqual(controller.phase, .ready); XCTAssertEqual(provider.submissions, 0)
            controller.send(contextID: prepared.id)
            for _ in 0..<1_000 where controller.phase == .storing || controller.phase == .enqueuing {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(controller.phase, .queued(nil)); XCTAssertNil(controller.preparationContextID)
            XCTAssertEqual(provider.submissions, 1); XCTAssertEqual(controller.messageIDs.count, 1)
            let saved = try await store.load(chatID: 42), value = try XCTUnwrap(saved)
            guard case let .acceptedBatch(ids) = value.disposition, let id = ids.first else {
                XCTFail("Controller did not retain complete native admission"); return
            }
            XCTAssertEqual(value.items, prepared.items)
            XCTAssertEqual(controller.messageIDs, ids.map(\.description)); XCTAssertFalse(controller.canSend)
            let done = expectation(description: "Controller voice native bytes"); var message: Message?
            let reading = (recordedVoiceMessage(box, id: id.nativeID) |> deliverOnMainQueue).start(next: { message = $0; done.fulfill() })
            defer { reading.dispose() }; await fulfillment(of: [done], timeout: 20)
            let media = try XCTUnwrap(message?.media.first as? TelegramMediaFile)
            XCTAssertEqual(message?.text, ""); XCTAssertNil(message?.groupingKey)
            XCTAssertEqual(media.attributes, [.Audio(isVoice: true, duration: 1, title: nil, performer: nil, waveform: waveform)])
            XCTAssertEqual(media.mimeType, "audio/ogg"); XCTAssertNil(media.size)
            let cachedDone = expectation(description: "Controller voice complete cache"); var cached: MediaResourceData?
            let cacheRead = (box.mediaBox.resourceData(media.resource, pathExtension: nil, option: .complete(waitUntilFetchStatus: false))
                |> take(1) |> deliverOnMainQueue).start(next: { cached = $0; cachedDone.fulfill() })
            defer { cacheRead.dispose() }; await fulfillment(of: [cachedDone], timeout: 20)
            let payload = try XCTUnwrap(cached); XCTAssertTrue(payload.complete)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: payload.path)), bytes)
            controller.send(contextID: prepared.id); controller.send()
            XCTAssertEqual(provider.submissions, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.directory.path))
            accepted = value
        }
        try await released()
        let frozen = try XCTUnwrap(accepted), box = try await open(path)
        let store = session(box, archive: archive), restoredLoad = try await store.load(chatID: 42)
        XCTAssertEqual(restoredLoad, frozen)
        let restored = try await store.restoreItems(draft: frozen)
        defer { for item in restored { try? item.discard() } }
        let controller = TelegramUploadController(), provider = RecordedVoiceLocalQueueProvider(postbox: box)
        controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        XCTAssertFalse(controller.restore(draft: frozen, items: restored, target: target, restorationEpoch: controller.recoveryRestoreEpoch))
        controller.send(); XCTAssertEqual(provider.submissions, 0)
        let record = frozen.items[0].file
        let remote = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey)
        if s3Enabled { XCTAssertNotNil(remote) }
        else {
            XCTAssertNil(remote)
            XCTAssertEqual(try database.execute("SELECT count(*) FROM \"\(database.schema)\".archive_file_events"), [["0"]])
            try await archive.setConversationFileSavingEnabled(identity: identity, enabled: true)
            let promoted = try await archive.resume(); XCTAssertEqual(promoted, 0)
            let stillAbsent = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey)
            XCTAssertNil(stillAbsent)
        }
    }

    // Validation after archive capture would leave forbidden preparations in S3.
    func testInvalidVoiceCaptionAndEncodedFactsRefuseBeforeArchiveCapture() async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let archiveRoot = try root(), box = try await open(root())
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: archiveRoot.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x68, count: 32) })
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "1", conversationID: "42", messageID: "synthetic-policy")
        try await archive.setConversationFileSavingEnabled(identity: identity, enabled: true)
        let store = session(box, archive: archive), target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic voice")
        let file = try await TelegramRecordedVoiceIO.prepare(samples: [Int16](repeating: 0, count: 1_000))
        defer { try? TelegramUploadFileIO.discard(file) }
        let metadata = try XCTUnwrap(file.metadata?.voice)
        let forged = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: file.url, directory: file.directory,
            metadata: .voice(.init(sampleCount: 999, plaintextSHA256: metadata.plaintextSHA256)))
        for (candidate, caption) in [(file, "Forbidden caption"), (forged, "")] {
            do {
                try await store.prepare(preparationID: UUID(), items: [.init(id: candidate.id, file: candidate)], isGrouped: false,
                    presentation: .file, target: target, captionInput: TelegramComposerInput(formattedText: .init(text: caption)), originalDraft: nil)
                XCTFail("Invalid voice preparation was captured")
            } catch {}
        }
        let pending = try await store.load(chatID: 42); XCTAssertNil(pending)
        XCTAssertEqual(try database.execute("SELECT count(*) FROM \"\(database.schema)\".archive_file_events"), [["0"]])
        let resumed = try await archive.resume(); XCTAssertEqual(resumed, 0)
    }

    // Catches losing explicit voice provenance, policy bypass, changed native bytes and stale retry admission.
    private func reopenAndQueue(s3Enabled: Bool) async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let archiveRoot = try root(), path = try root()
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: archiveRoot.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x68, count: 32) })
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "1", conversationID: "42", messageID: "synthetic-policy")
        try await archive.setConversationFileSavingEnabled(identity: identity, enabled: s3Enabled)
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic voice")
        let input = try TelegramComposerInput(formattedText: .init(text: ""))
        var expectedWaveform = Data(repeating: 0, count: 63); expectedWaveform[0] = 0x0c
        var saved: TelegramPendingUploadDraft?, bytes = Data()
        do {
            let box = try await open(path); previousBox = box
            let store = session(box, archive: archive)
            var pcm = [Int16](repeating: 0, count: 48_137)
            for index in 0..<100 { pcm[index] = 1_000 }
            let file = try await TelegramRecordedVoiceIO.prepare(samples: pcm)
            defer { try? TelegramUploadFileIO.discard(file) }
            bytes = try Data(contentsOf: file.url)
            let preparationID = UUID(), item = TelegramUploadBatchItem(id: file.id, file: file)
            try await store.prepare(preparationID: preparationID, items: [item], isGrouped: false, presentation: .file,
                target: target, captionInput: input, originalDraft: nil)
            let firstLoad = try await store.load(chatID: 42), first = try XCTUnwrap(firstLoad)
            XCTAssertEqual(first.schemaVersion, 11); XCTAssertEqual(first.items[0].metadata?.voice?.sampleCount, 48_137)
            XCTAssertEqual(first.items[0].metadata?.voice?.waveform, expectedWaveform)
            try await store.prepare(preparationID: preparationID, items: [item], isGrouped: false, presentation: .file,
                target: target, captionInput: input, originalDraft: nil)
            let retry = try await store.load(chatID: 42); XCTAssertEqual(retry?.items, first.items)
            try await store.save(preparationID: preparationID, chatID: 42, captionInput: input, disposition: .submissionStarted)
            saved = try await store.load(chatID: 42)
        }
        try await released()
        let frozen = try XCTUnwrap(saved), record = frozen.items[0].file
        XCTAssertEqual(record.state, s3Enabled ? .stored : .local)
        let remote = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey)
        if s3Enabled { XCTAssertNotNil(remote) } else { XCTAssertNil(remote) }
        do {
            let box = try await open(path); previousBox = box
            let store = session(box, archive: archive), loaded = try await store.load(chatID: 42)
            XCTAssertEqual(loaded, frozen)
            let restored = try await store.restoreItems(draft: frozen)
            defer { for item in restored { try? item.discard() } }
            XCTAssertEqual(restored.count, 1); XCTAssertEqual(restored[0].file.metadata, frozen.items[0].metadata)
            XCTAssertEqual(try Data(contentsOf: restored[0].file.url), bytes)
            let seeded = expectation(description: "Voice synthetic peers")
            let seed = (recordedVoicePeers(box) |> deliverOnMainQueue).start(next: { _ in seeded.fulfill() })
            defer { seed.dispose() }; await fulfillment(of: [seeded], timeout: 20)
            let queued = expectation(description: "Voice native queue"); var ids: [TelegramUploadQueueID] = []
            let submission = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: restored, draft: frozen, target: target,
                enqueue: { receipt, messages in telegramUploadBatchEnqueueLocally(postbox: box, receipt: receipt, messages: messages) }) { event in
                    switch event {
                    case let .accepted(value): ids = value; queued.fulfill()
                    case .rejected, .uncertain: XCTFail("Voice must be admitted with a complete native receipt"); queued.fulfill()
                    default: break
                    }
                }
            defer { submission.stop() }; await fulfillment(of: [queued], timeout: 20)
            let id = try XCTUnwrap(ids.first); XCTAssertEqual(ids.count, 1)
            let readDone = expectation(description: "Voice native payload"); var message: Message?
            let read = (recordedVoiceMessage(box, id: id.nativeID) |> deliverOnMainQueue).start(next: { message = $0; readDone.fulfill() })
            defer { read.dispose() }; await fulfillment(of: [readDone], timeout: 20)
            let native = try XCTUnwrap(message?.media.first as? TelegramMediaFile)
            XCTAssertEqual(message?.text, ""); XCTAssertNil(message?.groupingKey)
            XCTAssertEqual(native.mimeType, "audio/ogg"); XCTAssertNil(native.size)
            XCTAssertEqual(native.attributes, [.Audio(isVoice: true, duration: 1, title: nil, performer: nil, waveform: expectedWaveform)])
            XCTAssertTrue(native.previewRepresentations.isEmpty); XCTAssertTrue(native.videoThumbnails.isEmpty)
            XCTAssertNil(native.videoCover); XCTAssertNil(native.immediateThumbnailData)
            let cacheDone = expectation(description: "Voice exact native bytes"); var cache: MediaResourceData?
            let reading = (box.mediaBox.resourceData(native.resource, pathExtension: nil, option: .complete(waitUntilFetchStatus: false))
                |> take(1) |> deliverOnMainQueue).start(next: { cache = $0; cacheDone.fulfill() })
            defer { reading.dispose() }; await fulfillment(of: [cacheDone], timeout: 20)
            let cached = try XCTUnwrap(cache); XCTAssertTrue(cached.complete)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cached.path)), bytes)
            let acceptedLoad = try await store.load(chatID: 42), accepted = try XCTUnwrap(acceptedLoad)
            XCTAssertEqual(accepted.disposition, .acceptedBatch(messageIDs: ids)); XCTAssertEqual(accepted.items, frozen.items)
            saved = accepted
            let refused = expectation(description: "Stale voice admission refuses resend")
            let stale = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: restored, draft: frozen, target: target,
                enqueue: { receipt, messages in telegramUploadBatchEnqueueLocally(postbox: box, receipt: receipt, messages: messages) }) { event in
                    switch event {
                    case .rejected: refused.fulfill()
                    case .accepted, .uncertain: XCTFail("Accepted voice cannot be sent by a stale preparation"); refused.fulfill()
                    default: break
                    }
                }
            defer { stale.stop() }; await fulfillment(of: [refused], timeout: 20)
            let unchanged = try await store.load(chatID: 42); XCTAssertEqual(unchanged, accepted)
        }
        try await released()
        let reopened = try await open(path), final = try await session(reopened, archive: archive).load(chatID: 42)
        XCTAssertEqual(final, saved)
        if !s3Enabled {
            XCTAssertEqual(try database.execute("SELECT count(*) FROM \"\(database.schema)\".archive_file_events"), [["0"]])
            try await archive.setConversationFileSavingEnabled(identity: identity, enabled: true)
            let promoted = try await archive.resume(); XCTAssertEqual(promoted, 0)
            let stillAbsent = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey); XCTAssertNil(stillAbsent)
        }
    }

    private func session(_ box: Postbox, archive: ArchiveFileRepository) -> TelegramPendingUploadSession {
        TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
            files: { TelegramPendingUploadFiles(repository: archive) })
    }
    private weak var previousBox: Postbox?
    private func released() async throws {
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox, "Original encrypted Postbox must be released before reopening")
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: url) }; return url
    }
    private func open(_ root: URL) async throws -> Postbox {
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Encrypted voice fixture"); var box: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(value) = $0 { box = value; opened.fulfill() } })
        defer { opening.dispose() }; await fulfillment(of: [opened], timeout: 20)
        let result = try XCTUnwrap(box), ready = expectation(description: "Both voice MediaBox stores ready")
        ready.expectedFulfillmentCount = 2
        let storage = (result.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        let cache = (result.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        defer { storage.dispose(); cache.dispose() }; await fulfillment(of: [ready], timeout: 20)
        return result
    }
}

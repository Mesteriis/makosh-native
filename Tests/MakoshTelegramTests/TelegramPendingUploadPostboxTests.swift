import XCTest
import ImageIO
import CoreGraphics
import Foundation
import TelegramCore
import SwiftSignalKit
import MakoshCore
@testable import Postbox
@testable import MakoshTelegram

private func pendingFixtureRaw(_ box: Postbox, accountID: Int64, chatID: Int64, data: Data?) -> Signal<Data?, NoError> {
    box.transaction { transaction in
        let key = telegramPendingUploadKey(accountID: accountID, chatID: chatID)
        if let data { transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: data)) }
        return transaction.getPreferencesEntry(key: key)?.data
    }
}
@MainActor final class TelegramPendingUploadPostboxTests: XCTestCase {
    func testBatchCaptionSubmissionAndCancellationPreserveWholeOrderedPointer() async throws {
        let box = try await open(root()), repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let first = try pendingUploadBatchFixture()
        try await save(first, expected: nil, repository: repository).get()
        let session = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
        let edited = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Album 😀 caption"))
        for state: TelegramPendingUploadDisposition in [.prepared, .submissionStarted, .cancelled] {
            do {
                try await session.save(preparationID: first.id, chatID: 42, captionInput: edited, disposition: state)
            } catch { XCTFail("A shared caption/terminal write must retain all batch resources: \(state)"); return }
            let loaded = try await session.load(chatID: 42)
            let value = try XCTUnwrap(loaded)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            XCTAssertEqual((encoded["items"] as? [[String: Any]])?.count, 2)
            XCTAssertEqual(encoded["isGrouped"] as? Bool, true)
            XCTAssertEqual(value.items, first.items); XCTAssertEqual(value.captionInput, edited)
            XCTAssertEqual(value.disposition, state); XCTAssertNotEqual(value.revision, first.revision)
        }
        let stale = await save(first, expected: first.revision, repository: repository)
        if case .failure(.conflict) = stale {} else { XCTFail("A stale writer cannot resurrect the ordered preparation") }
    }

    func testLegacyPhotoPreparationCanUpgradeCaptionOptionsWithoutLosingItsResource() async throws {
        for version in [1, 2] {
            let original = try pendingUploadMutating(pendingUploadFixture()) {
                $0["schemaVersion"] = version
                var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
                attachment["kind"] = "photo"; file["attachment"] = attachment; $0["file"] = file
            }
            let box = try await open(root()), repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
            try await save(original, expected: nil, repository: repository).get()
            let session = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
            do {
                try await session.save(preparationID: original.id, chatID: 42, captionInput: original.captionInput,
                    captionAboveMedia: true, mediaSpoiler: true, disposition: .prepared)
            } catch { XCTFail("Legacy photo options must still upgrade on a user edit"); continue }
            let loaded = try await session.load(chatID: 42)
            XCTAssertEqual(loaded?.file, original.file); XCTAssertEqual(loaded?.schemaVersion, 3)
            XCTAssertEqual(loaded?.captionAboveMedia, true); XCTAssertEqual(loaded?.mediaSpoiler, true)
        }
    }

    func testSingleFileRestoreRejectsBatchBeforeExportingAnyItem() async throws {
        let box = try await open(root()), repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        var storageCalls = 0
        let session = TelegramPendingUploadSession(repository: repository, files: {
            storageCalls += 1; throw TelegramUploadFileError.unavailable
        })
        do {
            _ = try await session.restoreFile(draft: pendingUploadBatchFixture())
            XCTFail("An unwired single-file consumer must never export only the first batch item")
        } catch {}
        XCTAssertEqual(storageCalls, 0)
    }

    func testOrderedBatchReopensExactEncryptedS3FilesAndCoverWithoutDuplicateRetryObjects() async throws {
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let configPath = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: configPath))
        let path = try root(), archiveRoot = try root()
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: archiveRoot.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x58, count: 32) })
        let a = archiveRoot.appendingPathComponent("a.txt"), b = archiveRoot.appendingPathComponent("b.txt")
        try Data("First preserved bytes".utf8).write(to: a); try Data("Second preserved bytes".utf8).write(to: b)
        let videoURL = archiveRoot.appendingPathComponent("portrait.mov"), imageURL = archiveRoot.appendingPathComponent("cover.jpg")
        try await writeUploadVideoFixture(videoURL); try writeUploadVideoCoverFixture(imageURL)
        let first = try await TelegramUploadFileIO.stage(a, mode: .file), second = try await TelegramUploadFileIO.stage(b, mode: .file)
        let rawVideo = try await TelegramUploadFileIO.stage(videoURL, mode: .video)
        let cover = try await TelegramUploadVideoCoverIO.stage(imageURL, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        let video = TelegramUploadFile(id: rawVideo.id, name: rawVideo.name, size: rawVideo.size, mode: .video,
            pixelWidth: rawVideo.pixelWidth, pixelHeight: rawVideo.pixelHeight, url: rawVideo.url, directory: rawVideo.directory,
            video: rawVideo.video, videoCover: cover)
        let items = [first, video, second].map { TelegramUploadBatchItem(id: $0.id, file: $0) }
        addTeardownBlock { for item in items { try TelegramUploadFileIO.discard(item.file) } }
        let expected = try items.map { try Data(contentsOf: $0.file.url) }, coverBytes = try Data(contentsOf: cover.url)
        let preparationID = UUID(), input = try pendingUploadFixture().captionInput
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic ordered set")
        var saved: TelegramPendingUploadDraft?
        do {
            let box = try await open(path); previousBox = box
            let session = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
                files: { TelegramPendingUploadFiles(repository: archive) })
            try await session.prepare(preparationID: preparationID, items: items, isGrouped: true, target: target,
                captionInput: input, originalDraft: nil)
            saved = try await session.load(chatID: 42)
            try await session.prepare(preparationID: preparationID, items: items, isGrouped: true, target: target,
                captionInput: input, originalDraft: nil)
            let retried = try await session.load(chatID: 42)
            XCTAssertEqual(retried?.items, saved?.items, "A committed pointer retry must reuse every S3 object")
            try Data("Xirst preserved bytes".utf8).write(to: a)
            let substituted = try await TelegramUploadFileIO.stage(a, mode: .file)
            defer { try? TelegramUploadFileIO.discard(substituted) }
            let changed = [TelegramUploadBatchItem(id: first.id, file: substituted), items[1], items[2]]
            do {
                try await session.prepare(preparationID: preparationID, items: changed, isGrouped: true, target: target,
                    captionInput: input, originalDraft: nil)
                XCTFail("Same name and byte count cannot authorize replacement of a committed payload")
            } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
            do {
                try await session.prepare(preparationID: preparationID, items: Array(items.reversed()), isGrouped: true, target: target,
                    captionInput: input, originalDraft: nil)
                XCTFail("An initial-write retry cannot substitute a different order")
            } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        }
        for item in items { try TelegramUploadFileIO.discard(item.file) }
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let box = try await open(path), repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let session = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: archive) })
        let loaded = try await session.load(chatID: 42), draft = try XCTUnwrap(loaded)
        XCTAssertEqual(draft.items, saved?.items); XCTAssertEqual(draft.isGrouped, true)
        XCTAssertEqual(draft.captionInput, input); XCTAssertEqual(draft.items.map(\.id), items.map(\.id))
        let restored = try await session.restoreItems(draft: draft)
        addTeardownBlock { for item in restored { try TelegramUploadFileIO.discard(item.file) } }
        XCTAssertEqual(restored.map(\.id), items.map(\.id))
        XCTAssertEqual(restored.map { $0.file.name }, ["a.txt", "portrait.mov", "b.txt"])
        XCTAssertEqual(try restored.map { try Data(contentsOf: $0.file.url) }, expected)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored[1].file.videoCover).url), coverBytes)
        let beforeFailure = try Set(FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("makosh-upload-") })
        let forged = try pendingUploadMutating(draft) {
            var values = $0["items"] as! [[String: Any]], last = values[2]["file"] as! [String: Any]
            last["plaintextSHA256"] = String(repeating: "0", count: 64); values[2]["file"] = last; $0["items"] = values
        }
        XCTAssertTrue(forged.isValid, "Structurally valid metadata still needs authenticated archive verification")
        do { _ = try await session.restoreItems(draft: forged); XCTFail("A forged later resource cannot restore a partial batch") } catch {}
        let afterFailure = try Set(FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("makosh-upload-") })
        XCTAssertEqual(afterFailure, beforeFailure, "Later-item failure releases every newly restored file and video cover")
        for item in draft.items {
            let retained = try await archive.files(identity: item.file.identity, attachmentID: item.file.attachment.id)
            XCTAssertEqual(retained, [item.file])
        }
        try await session.save(preparationID: draft.id, chatID: 42, captionInput: input, disposition: .cancelled)
        let cancelled = try await session.load(chatID: 42)
        XCTAssertEqual(cancelled?.items, draft.items); XCTAssertEqual(cancelled?.disposition, .cancelled)
    }

    func testFailureAfterFirstS3UploadPreservesPreviousPointerAndRetainsOriginalBytes() async throws {
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let archiveRoot = try root(), box = try await open(root())
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: archiveRoot.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x59, count: 32) })
        let source = archiveRoot.appendingPathComponent("first.txt")
        let bytes = Data("Retained even after a later file fails".utf8)
        try bytes.write(to: source)
        let first = try await TelegramUploadFileIO.stage(source, mode: .file)
        let last = try await TelegramUploadFileIO.stage(source, mode: .file)
        defer { try? TelegramUploadFileIO.discard(first); try? TelegramUploadFileIO.discard(last) }
        let invalidPhoto = TelegramUploadFile(id: last.id, name: last.name, size: last.size, mode: .photo,
            pixelWidth: 40, pixelHeight: 20, url: last.url, directory: last.directory)
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let previous = try pendingUploadFixture(disposition: .cancelled)
        try await save(previous, expected: nil, repository: repository).get()
        let session = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: archive) })
        let preparationID = UUID(), firstID = UUID()
        do {
            try await session.prepare(preparationID: preparationID, items: [.init(id: firstID, file: first), .init(id: UUID(), file: invalidPhoto)],
                isGrouped: true, target: .init(accountID: 1, chatID: 42, title: "Synthetic failure"),
                captionInput: previous.captionInput, originalDraft: nil)
            XCTFail("An invalid later image must abort the whole preparation")
        } catch {}
        let loaded = try await session.load(chatID: 42)
        XCTAssertEqual(loaded, previous, "No partial preparation or new revision may replace the old pointer")
        let identity = TelegramPendingUploadDraft.archiveIdentity(accountID: 1, chatID: 42, preparationID: preparationID)
        let retained = try await archive.files(identity: identity, attachmentID: "prepared:" + firstID.uuidString.lowercased())
        XCTAssertEqual(retained.count, 1, "A successfully uploaded original remains archived after the later failure")
        let restored = try await TelegramPendingUploadFiles(repository: archive).restore(record: XCTUnwrap(retained.first),
            accountID: 1, chatID: 42, preparationID: preparationID, itemID: firstID)
        defer { try? TelegramUploadFileIO.discard(restored) }
        XCTAssertEqual(try Data(contentsOf: restored.url), bytes)
    }

    func testLegacyRetryRejectsSameNameAndSizeWithDifferentBytesWithoutChangingStoredPreparation() async throws {
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let configPath = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: configPath))
        let archiveRoot = try root()
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: archiveRoot.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x59, count: 32) })
        let source = archiveRoot.appendingPathComponent("same.txt")
        try Data("Original bytes".utf8).write(to: source)
        let original = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(original) }
        let box = try await open(root())
        let session = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
            files: { TelegramPendingUploadFiles(repository: archive) })
        let preparationID = UUID(), target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic legacy retry")
        let input = try pendingUploadFixture().captionInput
        try await session.prepare(preparationID: preparationID, file: original, target: target,
            captionInput: input, originalDraft: nil)
        let edited = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Verified retry"))
        try await session.prepare(preparationID: preparationID, file: original, target: target,
            captionInput: edited, originalDraft: nil)
        let loaded = try await session.load(chatID: 42), committed = try XCTUnwrap(loaded)
        XCTAssertEqual(committed.captionInput, edited)
        try Data("Replaced bytes".utf8).write(to: source)
        let substituted = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(substituted) }
        XCTAssertEqual(substituted.name, original.name); XCTAssertEqual(substituted.size, original.size)
        do {
            try await session.prepare(preparationID: preparationID, file: substituted, target: target,
                captionInput: input, originalDraft: nil)
            XCTFail("A retry must verify archived payload bytes before accepting caption changes")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        let after = try await session.load(chatID: 42)
        XCTAssertEqual(after, committed)
        let retained = try await archive.files(identity: committed.file.identity, attachmentID: "prepared")
        XCTAssertEqual(retained, [committed.file])
        let restored = try await session.restoreFile(draft: committed)
        addTeardownBlock { try TelegramUploadFileIO.discard(restored) }
        XCTAssertEqual(try Data(contentsOf: restored.url), Data("Original bytes".utf8))
    }

    func testVideoSessionReopensWithExactS3BytesAndDoesNotChangePreparationOnRetry() async throws {
        let configPath = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: configPath))
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let path = try root(), archiveRoot = try root()
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: archiveRoot.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x57, count: 32) })
        let source = archiveRoot.appendingPathComponent("portrait.mp4")
        try await writeUploadVideoFixture(source, rotated: true, timescale: 30)
        let file = try await TelegramUploadFileIO.stage(source, mode: .video)
        addTeardownBlock { try TelegramUploadFileIO.discard(file) }
        let bytes = try Data(contentsOf: file.url), preparationID = UUID()
        let input = try pendingUploadFixture().captionInput
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic video")
        do {
            let box = try await open(path); previousBox = box
            let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
            let session = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: archive) })
            try await session.prepare(preparationID: preparationID, file: file, target: target,
                captionInput: input, captionAboveMedia: true, mediaSpoiler: true, originalDraft: nil)
            let prepared = try await session.load(chatID: 42)
            XCTAssertEqual(prepared?.video, file.video)
            let video = try XCTUnwrap(file.video)
            let changed = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .video,
                pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: file.url, directory: file.directory,
                video: .init(width: video.width, height: video.height, duration: video.duration, hasAudio: video.hasAudio, inCollage: false))
            do {
                try await session.prepare(preparationID: preparationID, file: changed, target: target,
                    captionInput: input, captionAboveMedia: true, mediaSpoiler: true, originalDraft: nil)
                XCTFail("An unconfirmed pointer retry cannot replace frozen video preparation")
            } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
            try await session.save(preparationID: preparationID, chatID: 42, captionInput: input,
                captionAboveMedia: true, mediaSpoiler: true, disposition: .submissionStarted)
        }
        try TelegramUploadFileIO.discard(file)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let box = try await open(path)
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let session = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: archive) })
        let loaded = try await session.load(chatID: 42)
        let draft = try XCTUnwrap(loaded)
        XCTAssertEqual(draft.video, file.video)
        XCTAssertEqual(draft.captionInput, input)
        XCTAssertEqual(draft.disposition, .submissionStarted)
        let restored = try await session.restoreFile(draft: draft)
        addTeardownBlock { try TelegramUploadFileIO.discard(restored) }
        XCTAssertEqual(restored.video, file.video)
        XCTAssertEqual(try Data(contentsOf: restored.url), bytes)
        try await session.save(preparationID: preparationID, chatID: 42, captionInput: input,
            captionAboveMedia: true, mediaSpoiler: true, disposition: .cancelled)
        let retained = try await archive.files(identity: draft.file.identity, attachmentID: "prepared")
        XCTAssertEqual(retained, [draft.file])
        let tombstone = try await session.load(chatID: 42)
        XCTAssertEqual(tombstone?.disposition, .cancelled); XCTAssertEqual(tombstone?.video, file.video)
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

    private func save(_ draft: TelegramPendingUploadDraft, expected: UUID?, repository: TelegramPostboxPendingUploadRepository) async -> Result<Void, TelegramPendingUploadPersistenceError> {
        let done = expectation(description: "Pending CAS completed")
        var result: Result<Void, TelegramPendingUploadPersistenceError> = .failure(.unavailable)
        repository.save(draft, expectedRevision: expected) { result = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 20); return result
    }
    private func load(_ chat: Int64, repository: TelegramPostboxPendingUploadRepository) async -> Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError> {
        let done = expectation(description: "Pending load")
        var result: Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError> = .failure(.unavailable)
        let op = repository.load(chatID: chat) { result = $0; done.fulfill() }
        defer { op.dispose() }
        await fulfillment(of: [done], timeout: 20); return result
    }
    private func raw(_ box: Postbox, account: Int64 = 1, chat: Int64 = 42, data: Data? = nil) async -> Data? {
        let done = expectation(description: "Raw pending bytes")
        var result: Data?
        let op = (pendingFixtureRaw(box, accountID: account, chatID: chat, data: data) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { op.dispose() }
        await fulfillment(of: [done], timeout: 20); return result
    }
    private func seedThenRelease(_ path: URL, draft: TelegramPendingUploadDraft) async throws {
        let box = try await open(path); previousBox = box
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: draft.accountID)
        try await save(draft, expected: nil, repository: repository).get()
        let loaded = try await load(draft.chatID, repository: repository).get()
        XCTAssertEqual(loaded, draft)
    }
    func testReopenCASIdempotenceABAAndCancellationTombstone() async throws {
        let path = try root(), first = try pendingUploadFixture()
        try await seedThenRelease(path, draft: first)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox, "Must release original encrypted Postbox before reopen")
        let box = try await open(path), repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let reopened = try await load(42, repository: repository).get(); XCTAssertEqual(reopened, first)
        try await save(first, expected: nil, repository: repository).get() // exact idempotent retry
        let next = try pendingUploadMutating(first) { $0["revision"] = UUID().uuidString; $0["title"] = "B" }
        let absentConflict = await save(next, expected: nil, repository: repository)
        if case .failure(.conflict) = absentConflict {} else { XCTFail("Absent-only save must conflict") }
        try await save(next, expected: first.revision, repository: repository).get()
        let aba = try pendingUploadMutating(first) { $0["revision"] = UUID().uuidString }
        try await save(aba, expected: next.revision, repository: repository).get()
        let stale = await save(next, expected: first.revision, repository: repository)
        if case .failure(.conflict) = stale {} else { XCTFail("Stale ABA writer must conflict") }
        let sameRevision = try pendingUploadMutating(aba) { $0["title"] = "changed without new revision" }
        let invalidRevision = await save(sameRevision, expected: aba.revision, repository: repository)
        if case .failure(.conflict) = invalidRevision {} else { XCTFail("New revision required") }
        let cancelled = TelegramPendingUploadDraft(id: aba.id, accountID: 1, chatID: 42, title: aba.title,
            captionInput: aba.captionInput, originalDraft: aba.originalDraft, replyTarget: aba.replyTarget,
            file: aba.file, disposition: .cancelled)
        try await save(cancelled, expected: aba.revision, repository: repository).get()
        let tombstone = try await load(42, repository: repository).get(); XCTAssertEqual(tombstone, cancelled)
    }
    func testIsolationUnknownAndForeignPayloadPreserved() async throws {
        let box = try await open(root()), repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let first = try pendingUploadFixture(); try await save(first, expected: nil, repository: repository).get()
        let foreignRepository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 2)
        let foreign = try await load(42, repository: foreignRepository).get(); XCTAssertNil(foreign)
        let otherChat = try await load(43, repository: repository).get(); XCTAssertNil(otherChat)
        let rawBytes = await raw(box)
        let bytes = try XCTUnwrap(rawBytes)
        // Copy valid bytes into a different scoped key; decoder must refuse scope confusion.
        _ = await raw(box, account: 2, data: bytes)
        let foreignLoad = await load(42, repository: foreignRepository)
        if case .failure(.incompatibleData) = foreignLoad {} else { XCTFail("Foreign scope must fail closed") }
        for bad in [Data("unknown-owner".utf8), Data(repeating: 0x41, count: 512 * 1024 + 1)] {
            _ = await raw(box, data: bad)
            let failedLoad = await load(42, repository: repository)
            if case .failure(.incompatibleData) = failedLoad {} else { XCTFail("Unknown bytes must reject") }
            let failedSave = await save(first, expected: first.revision, repository: repository)
            if case .failure(.incompatibleData) = failedSave {} else { XCTFail("Unknown bytes must not overwrite") }
            let retained = await raw(box); XCTAssertEqual(retained, bad)
        }
    }

    func testPendingCaptionAndFileReopenTogetherAndCancellationRetainsArchive() async throws {
        try await pendingCaptionAndFileReopen(mode: .file)
    }
    func testPendingPhotoSpoilerAndPlacementReopenWithRealS3BytesAndCancellationRetainChoice() async throws {
        try await pendingCaptionAndFileReopen(mode: .photo)
    }
    private func pendingCaptionAndFileReopen(mode: TelegramUploadMode) async throws {
        guard let configPath = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else {
            throw MessageArchiveError.invalid
        }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: configPath))
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let path = try root(), archiveRoot = try root()
        let source = archiveRoot.appendingPathComponent(mode == .photo ? "synthetic.jpg" : "synthetic.txt")
        if mode == .photo {
            let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
                bytesPerRow: 40, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
            context.setFillColor(gray: 0.4, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            let image = try XCTUnwrap(context.makeImage())
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        } else { try Data("Synthetic pending file e\u{301} 😀".utf8).write(to: source) }
        let staged = try await TelegramUploadFileIO.stage(source, mode: mode)
        let bytes = try Data(contentsOf: staged.url)
        addTeardownBlock { try TelegramUploadFileIO.discard(staged) }
        func archiveRepository() throws -> ArchiveFileRepository {
            try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
                configuration: configuration, spoolDirectory: archiveRoot.appendingPathComponent("queue"),
                keyProvider: { _, _ in Data(repeating: 0x56, count: 32) })
        }
        let preparationID = UUID()
        let savedFile = try await TelegramPendingUploadFiles(repository: archiveRepository()).save(
            file: staged, accountID: 1, chatID: 42, preparationID: preparationID)
        let reply = TelegramComposerReplyTarget(peerID: 42, namespace: Namespaces.Message.Cloud, messageID: 19, threadID: 23)
        let original = TelegramComposerDraft(accountID: 1, chatID: 42, text: "Original input", replyTarget: reply)
        let caption = try pendingUploadFixture().captionInput
        let pending = TelegramPendingUploadDraft(id: preparationID, accountID: 1, chatID: 42,
            title: "Synthetic recipient", captionInput: caption, captionAboveMedia: mode == .photo, mediaSpoiler: mode == .photo, originalDraft: original, replyTarget: reply,
            file: savedFile, disposition: .submissionStarted)
        try await seedThenRelease(path, draft: pending)
        try TelegramUploadFileIO.discard(staged)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)

        let box = try await open(path), repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let result = try await load(42, repository: repository).get()
        let restored = try XCTUnwrap(result)
        XCTAssertEqual(restored.captionInput, caption)
        XCTAssertEqual(restored.captionAboveMedia, mode == .photo)
        XCTAssertEqual(restored.mediaSpoiler, mode == .photo)
        XCTAssertEqual(Array(restored.captionInput.formattedText.text.utf8), Array(caption.formattedText.text.utf8))
        XCTAssertEqual(restored.originalDraft, original)
        XCTAssertEqual(restored.replyTarget, reply)
        XCTAssertEqual(restored.disposition, .submissionStarted, "Unknown enqueue outcome must remain explicit after reopen")
        let reopenedArchive = try archiveRepository()
        let recoveredFile = try await TelegramPendingUploadFiles(repository: reopenedArchive).restore(
            record: restored.file, accountID: 1, chatID: 42, preparationID: preparationID)
        addTeardownBlock { try TelegramUploadFileIO.discard(recoveredFile) }
        XCTAssertEqual(try Data(contentsOf: recoveredFile.url), bytes)
        XCTAssertEqual(recoveredFile.name, staged.name)
        let session = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: reopenedArchive) })
        try await session.save(preparationID: restored.id, chatID: restored.chatID, captionInput: restored.captionInput,
            captionAboveMedia: restored.captionAboveMedia, mediaSpoiler: restored.mediaSpoiler, disposition: .cancelled)
        let retainedFiles = try await reopenedArchive.files(identity: savedFile.identity, attachmentID: "prepared")
        XCTAssertEqual(retainedFiles, [savedFile], "Cancelling preparation retains immutable archived bytes")
        let retainedDraft = try await load(42, repository: repository).get()
        XCTAssertEqual(retainedDraft?.disposition, .cancelled)
        XCTAssertEqual(retainedDraft?.captionAboveMedia, mode == .photo)
        XCTAssertEqual(retainedDraft?.mediaSpoiler, mode == .photo)
        let lateWrite = await save(restored, expected: restored.revision, repository: repository)
        if case .failure(.conflict) = lateWrite {} else { XCTFail("Late writer must not resurrect the cancelled preparation") }
    }
}

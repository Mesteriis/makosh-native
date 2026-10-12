import XCTest
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

struct SourceFactsTestArchive {
    let database: PendingFilesTestDatabase
    let root: URL
    let configuration: S3ObjectStoreConfiguration
    let archive: ArchiveFileRepository
    var accountID: Int64 = 1
    var postboxPath: URL { root.appendingPathComponent("postbox") }
    var target: TelegramUploadTarget { .init(accountID: accountID, chatID: 42, title: "Synthetic source facts") }
    var identity: MessageArchiveIdentity {
        .init(service: "telegram", accountID: String(accountID), conversationID: "42", messageID: "synthetic-policy")
    }
    @MainActor func session(_ box: Postbox) -> TelegramPendingUploadSession {
        TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: accountID),
            files: { TelegramPendingUploadFiles(repository: archive) })
    }
    func localRecords() throws -> [String] {
        let directory = root.appendingPathComponent("queue")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "local" }.map(\.lastPathComponent).sorted()
    }
}

@MainActor class TelegramSourceFactsIntegrationTestCase: XCTestCase {
    func sourceFactsArchive(accountID: Int64 = 1) async throws -> SourceFactsTestArchive {
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath:
            XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: root.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x59, count: 32) })
        let result = SourceFactsTestArchive(database: database, root: root, configuration: configuration, archive: archive, accountID: accountID)
        try await archive.setConversationFileSavingEnabled(identity: result.identity, enabled: false)
        return result
    }

    func sourceFactsOpen(_ path: URL) async throws -> Postbox {
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Encrypted source-facts Postbox")
        var box: Postbox?
        let opening = (openPostbox(basePath: path.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false, isReadOnly: false,
            useCopy: false, useCaches: false, removeDatabaseOnError: false) |> deliverOnMainQueue).start(next: {
                if case let .postbox(value) = $0 { box = value; opened.fulfill() }
            })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let result = try XCTUnwrap(box), ready = expectation(description: "Source-facts MediaBox stores ready")
        ready.expectedFulfillmentCount = 2
        let a = (result.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        let b = (result.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        defer { a.dispose(); b.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return result
    }

    func sourceFactsValue<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Source-facts native transaction")
        var result: T?
        let operation = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { operation.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }

    func sourceFacts(_ raw: TelegramUploadFile, itemID: UUID? = nil, role: TelegramUploadSourceFacts.Role = .prepared,
                     mime: String, image: TelegramUploadSourceFacts.ImageProbe = .notImage) throws -> TelegramUploadSourceFacts {
        // Independent fixture identity: no source classifier or source-facts IO computes the expectation.
        let bytes = try Data(contentsOf: raw.url)
        return .init(itemID: itemID ?? raw.id, role: role, name: raw.name, byteCount: Int64(bytes.count),
            plaintextSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            selectionMIME: mime, image: image, grouping: .ordinary)
    }

    func sourceFactsDocument(_ fixture: SourceFactsTestArchive, name: String, text: String) async throws -> TelegramUploadBatchItem {
        let source = fixture.root.appendingPathComponent(name)
        try Data(text.utf8).write(to: source)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        return .init(id: raw.id, file: raw, sourceFacts: try sourceFacts(raw, mime: "text/plain"))
    }

    func sourceFactsSmallImage(_ fixture: SourceFactsTestArchive, name: String = "small.png") async throws -> TelegramUploadBatchItem {
        let source = fixture.root.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 39, height: 48, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        return .init(id: raw.id, file: raw, sourceFacts: try sourceFacts(raw, mime: "image/png", image: .decoded(width: 39, height: 48)))
    }

    func sourceFactsPhoto(_ fixture: SourceFactsTestArchive, name: String = "photo.jpg") async throws -> TelegramUploadBatchItem {
        let source = fixture.root.appendingPathComponent(name)
        try writeUploadVideoCoverFixture(source) // 40×80 logical source, independently fixed fixture.
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        do {
            let jpeg = try await TelegramUploadFileIO.stage(raw.url, mode: .photo)
            let prepared = TelegramUploadFile(id: jpeg.id, name: name, size: jpeg.size, mode: .photo,
                pixelWidth: jpeg.pixelWidth, pixelHeight: jpeg.pixelHeight, url: jpeg.url, directory: jpeg.directory)
            return .init(id: raw.id, file: prepared, originalFile: raw,
                sourceFacts: try sourceFacts(raw, role: .original, mime: "image/jpeg", image: .decoded(width: 40, height: 80)))
        } catch { try? TelegramUploadFileIO.discard(raw); throw error }
    }

    func sourceFactsLoad(_ store: TelegramPendingUploadSession) async throws -> TelegramPendingUploadDraft {
        let loaded = try await store.load(chatID: 42)
        return try XCTUnwrap(loaded)
    }
}

@MainActor final class TelegramSourceFactsRecoveryTests: TelegramSourceFactsIntegrationTestCase {
    // Catches dropping facts on reordered pointers/reopen or recapturing during metadata-only edits with OFF.
    func testSourceFactsKeepOrderedRawBindingsAcrossCASRemovalAndEncryptedReopenWithoutS3() async throws {
        let fixture = try await sourceFactsArchive()
        let small = try await sourceFactsSmallImage(fixture), photo = try await sourceFactsPhoto(fixture)
        let items = [small, photo]
        defer { items.forEach { try? $0.discard() } }
        let expectedFacts = items.map(\.sourceFacts), preparationID = UUID()
        var saved: TelegramPendingUploadDraft?
        weak var previous: Postbox?
        do {
            let box = try await sourceFactsOpen(fixture.postboxPath); previous = box
            let store = fixture.session(box)
            do {
                try await store.prepare(preparationID: preparationID, items: items, isGrouped: true, presentation: .media,
                    target: fixture.target, captionInput: .empty, originalDraft: nil)
            } catch { return XCTFail("Complete source facts must prepare as schema14: \(error)") }
            let original = try await sourceFactsLoad(store)
            XCTAssertEqual(original.schemaVersion, 17); XCTAssertEqual(original.items.map(\.sourceFacts), expectedFacts)
            XCTAssertTrue(original.items.allSatisfy { $0.file.state == .local })
            XCTAssertEqual(original.items[1].originalFile?.state, .local)
            // Exact lost-ACK retry retains all resource identities instead of storing another copy.
            try await store.prepare(preparationID: preparationID, items: items, isGrouped: true, presentation: .media,
                target: fixture.target, captionInput: .empty, originalDraft: nil)
            let retried = try await sourceFactsLoad(store)
            XCTAssertEqual(retried.items, original.items)
            let caption = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Latest 😀"))
            try await store.save(preparationID: preparationID, chatID: 42, captionInput: caption, disposition: .prepared)
            try await store.updateItems(preparationID: preparationID, previousIDs: items.map(\.id), previousGrouping: true,
                previousPresentation: .media, orderedIDs: [items[1].id, items[0].id], isGrouped: true,
                presentation: .media, target: fixture.target)
            let reordered = try await sourceFactsLoad(store)
            XCTAssertEqual(reordered.items, [original.items[1], original.items[0]])
            XCTAssertEqual(reordered.captionInput, caption)
            do {
                try await store.updateItems(preparationID: preparationID, previousIDs: items.map(\.id), previousGrouping: true,
                    previousPresentation: .media, orderedIDs: [items[0].id], isGrouped: false,
                    presentation: .file, target: fixture.target)
                XCTFail("An old order must not remove from the newer source-facts pointer")
            } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
            try await store.updateItems(preparationID: preparationID, previousIDs: reordered.items.map(\.id), previousGrouping: true,
                previousPresentation: .media, orderedIDs: [items[0].id], isGrouped: false,
                presentation: .file, target: fixture.target)
            let removed = try await sourceFactsLoad(store)
            XCTAssertEqual(removed.items, [original.items[0]]); XCTAssertEqual(removed.presentation, .file)
            XCTAssertFalse(removed.isGrouped); XCTAssertEqual(removed.items[0].sourceFacts, expectedFacts[0])
            let allRecords = original.items.flatMap { [$0.file] + ($0.originalFile.map { [$0] } ?? []) }
            XCTAssertEqual(try fixture.localRecords(), allRecords.map { $0.id.uuidString.lowercased() + ".local" }.sorted())
            for record in allRecords {
                let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                XCTAssertNil(object)
            }
            saved = removed
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("small.png"))
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("photo.jpg"))
        }
        for _ in 0..<100 where previous != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previous)
        let box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
        let restoredDraft = try await sourceFactsLoad(store)
        XCTAssertEqual(restoredDraft, saved)
        let restored = try await store.restoreItems(draft: restoredDraft)
        defer { restored.forEach { try? $0.discard() } }
        XCTAssertEqual(restored.map(\.sourceFacts), [expectedFacts[0]])
        XCTAssertEqual(restored.map(\.id), [items[0].id])
        XCTAssertEqual(try Data(contentsOf: restored[0].file.url), try Data(contentsOf: items[0].file.url))
        XCTAssertEqual(try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events"), [["0"]])
        try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
        let promoted = try await fixture.archive.resume(); XCTAssertEqual(promoted, 0)
        let absent = try await S3ObjectStore(configuration: fixture.configuration).head(key: restoredDraft.items[0].file.objectKey)
        XCTAssertNil(absent)
    }

    // Catches validating a later item's source hash only after earlier bytes have already entered storage.
    func testLaterForgedSourceFactsRejectTheWholeBatchBeforeAnyArchiveCopy() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let first = try await sourceFactsDocument(fixture, name: "first.txt", text: "first source")
        let second = try await sourceFactsDocument(fixture, name: "second.txt", text: "second source")
        defer { try? first.discard(); try? second.discard() }
        let facts = try XCTUnwrap(second.sourceFacts)
        let forged = TelegramUploadSourceFacts(itemID: second.id, role: .prepared, name: facts.name, byteCount: facts.byteCount,
            plaintextSHA256: String(repeating: "a", count: 64), selectionMIME: "text/plain", image: .notImage, grouping: .ordinary)
        let items = [first, TelegramUploadBatchItem(id: second.id, file: second.file, sourceFacts: forged)]
        do {
            try await fixture.session(box).prepare(preparationID: UUID(), items: items, isGrouped: true, presentation: .file,
                target: fixture.target, captionInput: .empty, originalDraft: nil)
            XCTFail("A different raw digest cannot authenticate source decisions")
        } catch { }
        XCTAssertEqual(try fixture.localRecords(), [])
        XCTAssertEqual(try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events"), [["0"]])
        let pointer = try await fixture.session(box).load(chatID: 42); XCTAssertNil(pointer)
    }

    // Catches treating source options as an unordered set or automatically enabling Media after a reorder.
    func testOrderedWebPReorderNormalizesAtomicallyAndRequiresExplicitMediaSelection() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let source = fixture.root.appendingPathComponent("source.webp")
        try writeUploadWebPFixture(source, fixture: .staticLossless)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        let typed = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory,
            metadata: .webP(.init(width: 320, height: 160)))
        let webP = TelegramUploadBatchItem(id: raw.id, file: typed,
            sourceFacts: try sourceFacts(raw, mime: "image/webp", image: .decoded(width: 320, height: 160)))
        defer { try? webP.discard() }
        let photo = try await sourceFactsPhoto(fixture)
        defer { try? photo.discard() }
        let items = [webP, photo], store = fixture.session(box), id = UUID()
        try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .media,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        let initial = try await sourceFactsLoad(store), copies = try fixture.localRecords()
        XCTAssertEqual(initial.schemaVersion, 17); XCTAssertEqual(initial.items.map(\.sourceFacts), items.map(\.sourceFacts))
        XCTAssertEqual(initial.presentation, .media); XCTAssertFalse(initial.isGrouped)
        let reversedIDs = items.reversed().map(\.id)
        do {
            try await store.updateItems(preparationID: id, previousIDs: items.map(\.id), previousGrouping: false,
                previousPresentation: .media, orderedIDs: reversedIDs, isGrouped: false,
                presentation: .media, target: fixture.target)
            XCTFail("Trailing WebP removes the Media option even while the photo remains")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .incompatibleData) }
        let refused = try await sourceFactsLoad(store)
        XCTAssertEqual(refused, initial, "An invalid requested mode must not partially reorder the durable pointer")
        try await store.updateItems(preparationID: id, previousIDs: items.map(\.id), previousGrouping: false,
            previousPresentation: .media, orderedIDs: reversedIDs, isGrouped: false,
            presentation: .file, target: fixture.target)
        let reversed = try await sourceFactsLoad(store)
        XCTAssertEqual(reversed.items, Array(initial.items.reversed()))
        XCTAssertEqual(reversed.presentation, .file); XCTAssertFalse(reversed.isGrouped)
        do {
            try await store.updatePresentation(preparationID: id, orderedIDs: reversedIDs, previousPresentation: .file,
                previousGrouping: false, presentation: .media, isGrouped: false, target: fixture.target)
            XCTFail("Media cannot be selected while ordered source options omit it")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .incompatibleData) }
        let stillReversed = try await sourceFactsLoad(store)
        XCTAssertEqual(stillReversed, reversed)
        try await store.updateItems(preparationID: id, previousIDs: reversedIDs, previousGrouping: false,
            previousPresentation: .file, orderedIDs: items.map(\.id), isGrouped: false,
            presentation: .file, target: fixture.target)
        let restoredOrder = try await sourceFactsLoad(store)
        XCTAssertEqual(restoredOrder.items, initial.items)
        XCTAssertEqual(restoredOrder.presentation, .file, "Restored Media availability must not enable it automatically")
        XCTAssertFalse(restoredOrder.isGrouped)
        try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
            previousGrouping: false, presentation: .media, isGrouped: false, target: fixture.target)
        let explicit = try await sourceFactsLoad(store)
        XCTAssertEqual(explicit.items, initial.items); XCTAssertEqual(explicit.presentation, .media)
        XCTAssertFalse(explicit.isGrouped)
        XCTAssertEqual(try fixture.localRecords(), copies, "Metadata-only order/mode edits must not create new archive copies")
        XCTAssertEqual(try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events"), [["0"]])
        for record in initial.items.flatMap({ [$0.file] + ($0.originalFile.map { [$0] } ?? []) }) {
            XCTAssertEqual(record.state, .local)
            let object = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
            XCTAssertNil(object)
        }
    }

    // Catches trusting authenticated metadata dimensions without re-probing the restored raw source.
    func testRestorationRejectsChangedLogicalFactsEvenWithTheCorrectArchivedDigest() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let photo = try await sourceFactsPhoto(fixture)
        defer { try? photo.discard() }
        let store = fixture.session(box), id = UUID()
        do {
            try await store.prepare(preparationID: id, items: [photo], isGrouped: false, presentation: .media,
                target: fixture.target, captionInput: .empty, originalDraft: nil)
        } catch { return XCTFail("Complete photo source facts must prepare before restore test: \(error)") }
        let original = try await sourceFactsLoad(store), item = original.items[0], facts = try XCTUnwrap(item.sourceFacts)
        let altered = TelegramUploadSourceFacts(itemID: facts.itemID, role: facts.role, name: facts.name, byteCount: facts.byteCount,
            plaintextSHA256: facts.plaintextSHA256, selectionMIME: facts.selectionMIME,
            image: .decoded(width: 41, height: 80), grouping: .ordinary)
        let forged = try TelegramPendingUploadDraft(id: original.id, accountID: 1, chatID: 42, title: original.title,
            captionInput: original.captionInput, originalDraft: nil, replyTarget: nil,
            items: [.init(id: item.id, file: item.file, video: item.video, originalFile: item.originalFile,
                metadata: item.metadata, sourceFacts: altered)], isGrouped: false, presentation: .media)
        XCTAssertTrue(forged.isValid, "Record binding alone cannot establish decoded logical size")
        do {
            let restored = try await store.restoreItems(draft: forged)
            restored.forEach { try? $0.discard() }
            XCTFail("Fresh raw decoding must reject the substituted logical facts")
        } catch { }
        let unchanged = try await sourceFactsLoad(store)
        XCTAssertEqual(unchanged, original)
    }
}

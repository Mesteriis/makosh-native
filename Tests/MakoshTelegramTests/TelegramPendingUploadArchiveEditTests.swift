import XCTest
import Foundation
import MakoshCore
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadArchiveEditTests: TelegramSourceFactsIntegrationTestCase {
    // Catches a visible edit without durable cache invalidation, stale ZIP reuse, or losing the remaining originals on rebuild.
    func testControllerEditsInactiveArchiveAndEnqueuesTheRebuiltMembers() async throws {
        let fixture = try await sourceFactsArchive(accountID: -1), box = try await sourceFactsOpen(fixture.postboxPath)
        let originals = [try await sourceFactsPhoto(fixture, name: "first.jpg"),
                         try await sourceFactsPhoto(fixture, name: "second.jpg"),
                         try await sourceFactsPhoto(fixture, name: "third.jpg")]
        defer { originals.forEach { try? $0.discard() } }
        let persistence = ArchiveEditACKRepository(TelegramPostboxPendingUploadRepository(postbox: box, accountID: -1))
        let store = TelegramPendingUploadSession(repository: persistence, files: { TelegramPendingUploadFiles(repository: fixture.archive) })
        let controller = TelegramUploadController()
        controller.bind(provider: TelegramSyntheticUploadProvider(postbox: box), recoveryStore: store, requiresRecovery: true)
        defer { controller.clear() }
        controller.prepare(sources: ["first.jpg", "second.jpg", "third.jpg"].map {
            .init(source: fixture.root.appendingPathComponent($0), mode: .photo)
        }, isGrouped: false, target: fixture.target, captionInput: .empty)
        try await ready(controller)
        let id = try XCTUnwrap(controller.preparationContextID)
        XCTAssertTrue(controller.updatePresentation(.archive, contextID: id, revision: controller.itemsRevision))
        try await ready(controller)
        let before = try await sourceFactsLoad(store), descriptor = try XCTUnwrap(before.archive)
        XCTAssertFalse(controller.canEditItems, "The reference's one-ZIP row has no member editor")
        XCTAssertTrue(controller.updatePresentation(.file, contextID: id, revision: controller.itemsRevision))
        try await ready(controller)
        let ids = controller.items.map(\.id), stale = controller.itemsRevision, count = try recordCount(fixture)
        persistence.failNextSaveACK = true
        guard controller.moveItem(id: ids[2], to: 0, contextID: id, revision: stale) else {
            return XCTFail("File mode must permit edits with an inactive Archive cache")
        }
        for _ in 0..<500 where !controller.canRetryRecovery { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(controller.canRetryRecovery); XCTAssertFalse(controller.canSend)
        let committed = try await sourceFactsLoad(store)
        XCTAssertNil(committed.archive); XCTAssertEqual(committed.items.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(try recordCount(fixture), count)
        controller.retryRecovery()
        try await ready(controller)
        XCTAssertFalse(controller.removeItem(id: ids[1], contextID: id, revision: stale))
        let moved = try await sourceFactsLoad(store)
        XCTAssertNil(moved.archive); XCTAssertEqual(moved.items.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertTrue(controller.removeItem(id: ids[1], contextID: id, revision: controller.itemsRevision))
        try await ready(controller)
        XCTAssertEqual(controller.items.map(\.id), [ids[2], ids[0]])
        XCTAssertEqual(try recordCount(fixture), count)
        controller.bind(provider: nil)
        controller.bind(provider: TelegramSyntheticUploadProvider(postbox: box), recoveryStore: store, requiresRecovery: true)
        let saved = try await sourceFactsLoad(store), bundle = try await store.restoreBundle(draft: saved)
        guard controller.restore(draft: saved, bundle: bundle, target: fixture.target, restorationEpoch: controller.recoveryRestoreEpoch) else {
            try bundle.discard(); return XCTFail("Edited ordinary pointer must restore without its old ZIP")
        }
        XCTAssertTrue(controller.updatePresentation(.archive, contextID: id, revision: controller.itemsRevision))
        try await ready(controller)
        let rebuilt = try await sourceFactsLoad(store), zip = try XCTUnwrap(rebuilt.archive)
        XCTAssertNotEqual(zip.id, descriptor.id); XCTAssertEqual(zip.members.map(\.entryName), ["third.jpg", "first.jpg"])
        XCTAssertEqual(controller.presentedItems.count, 1); XCTAssertEqual(try recordCount(fixture), count + 1)
        controller.send()
        for _ in 0..<500 where controller.phase != .queued(nil) && controller.phase != .uncertain && controller.phase != .rejected {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.phase, .queued(nil))
        let accepted = try await sourceFactsLoad(store)
        guard case let .acceptedBatch(queue) = accepted.disposition else { return XCTFail("Rebuilt ZIP must reach the native queue") }
        XCTAssertEqual(queue.count, 1); XCTAssertEqual(accepted.archive, zip)
        XCTAssertEqual(try recordCount(fixture), count + 1)
    }

    // Catches a grouping action blocked by an inactive cache or a controller/store ZIP mismatch after saving it.
    func testControllerGroupsMediaWhileKeepingTheSameZIP() async throws {
        let fixture = try await sourceFactsArchive(accountID: -1), box = try await sourceFactsOpen(fixture.postboxPath)
        let originals = [try await sourceFactsPhoto(fixture, name: "first.jpg"), try await sourceFactsPhoto(fixture, name: "second.jpg")]
        defer { originals.forEach { try? $0.discard() } }
        let store = fixture.session(box), controller = TelegramUploadController()
        controller.bind(provider: TelegramSyntheticUploadProvider(postbox: box), recoveryStore: store, requiresRecovery: true)
        defer { controller.clear() }
        controller.prepare(sources: ["first.jpg", "second.jpg"].map {
            .init(source: fixture.root.appendingPathComponent($0), mode: .photo)
        }, isGrouped: false, target: fixture.target, captionInput: .empty)
        try await ready(controller)
        let id = try XCTUnwrap(controller.preparationContextID)
        XCTAssertTrue(controller.updatePresentation(.archive, contextID: id, revision: controller.itemsRevision)); try await ready(controller)
        XCTAssertTrue(controller.updatePresentation(.media, contextID: id, revision: controller.itemsRevision)); try await ready(controller)
        let before = try await sourceFactsLoad(store), count = try recordCount(fixture)
        guard controller.updateGrouping(true, contextID: id, revision: controller.itemsRevision) else {
            return XCTFail("Media grouping must remain available with the inactive cache")
        }
        try await ready(controller)
        let grouped = try await sourceFactsLoad(store)
        XCTAssertTrue(controller.isGrouped); XCTAssertTrue(grouped.isGrouped)
        XCTAssertEqual(grouped.archive, before.archive); XCTAssertEqual(try recordCount(fixture), count)
    }

    // Catches a stale ZIP after member edits, recapturing original files, or purging the old immutable archive.
    func testMemberEditsInvalidateTheCacheAndRebuildOnlyTheNewZIPForBothPolicies() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "First"),
                         try await sourceFactsDocument(fixture, name: "second.txt", text: "Second"),
                         try await sourceFactsDocument(fixture, name: "third.txt", text: "Third")]
            defer { items.forEach { try? $0.discard() } }
            let id = UUID(), input = try TelegramComposerInput(formattedText: .init(text: "Keep raw caption 😀"))
            try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: input, originalDraft: nil)
            try await mode(store, fixture, id, items, from: .file, to: .archive)
            let archived = try await sourceFactsLoad(store), old = try XCTUnwrap(archived.archive), count = try recordCount(fixture)
            do {
                try await store.updateItems(preparationID: id, previousIDs: items.map(\.id), previousGrouping: false,
                    previousPresentation: .archive, orderedIDs: items.reversed().map(\.id), isGrouped: false,
                    presentation: .archive, target: fixture.target)
                XCTFail("Active Archive must not admit member edits")
            } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .incompatibleData) }
            let unchanged = try await sourceFactsLoad(store); XCTAssertEqual(unchanged, archived)
            XCTAssertEqual(try recordCount(fixture), count)
            try await mode(store, fixture, id, items, from: .archive, to: .file)
            let originalIDs = items.map(\.id), reordered = [items[2].id, items[0].id, items[1].id]
            do {
                try await store.updateItems(preparationID: id, previousIDs: originalIDs, previousGrouping: false,
                    previousPresentation: .file, orderedIDs: reordered, isGrouped: false, presentation: .file, target: fixture.target)
            } catch { XCTFail("Inactive Archive cache must permit reorder: \(error)"); continue }
            let moved = try await sourceFactsLoad(store)
            XCTAssertEqual(moved.schemaVersion, 15); XCTAssertNil(moved.archive)
            XCTAssertEqual(moved.items.map(\.id), reordered); XCTAssertEqual(moved.captionInput, input)
            let remaining = Array(reordered.prefix(2))
            try await store.updateItems(preparationID: id, previousIDs: reordered, previousGrouping: false,
                previousPresentation: .file, orderedIDs: remaining, isGrouped: false, presentation: .file, target: fixture.target)
            let edited = try await sourceFactsLoad(store)
            XCTAssertNil(edited.archive); XCTAssertEqual(try recordCount(fixture), count)
            let oldBundle = try await store.restoreBundle(draft: archived)
            XCTAssertEqual(oldBundle.archive?.members.map(\.entryName), ["first.txt", "second.txt", "third.txt"])
            try oldBundle.discard()
            // Lost-ACK replay must not resurrect the old descriptor or add captures.
            try await store.updateItems(preparationID: id, previousIDs: reordered, previousGrouping: false,
                previousPresentation: .file, orderedIDs: remaining, isGrouped: false, presentation: .file, target: fixture.target)
            try await store.updatePresentation(preparationID: id, orderedIDs: remaining, previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            let rebuilt = try await sourceFactsLoad(store), new = try XCTUnwrap(rebuilt.archive)
            XCTAssertNotEqual(new.id, old.id); XCTAssertEqual(new.members.map(\.entryName), ["third.txt", "first.txt"])
            XCTAssertEqual(rebuilt.items, [archived.items[2], archived.items[0]])
            XCTAssertEqual(rebuilt.captionInput, input); XCTAssertEqual(try recordCount(fixture), count + 1)
            XCTAssertEqual(new.file.state, enabled ? .stored : .local)
            let restored = try await store.restoreBundle(draft: rebuilt)
            XCTAssertEqual(restored.archive?.members.map(\.entryName), ["third.txt", "first.txt"])
            try restored.discard()
            if !enabled {
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                let promoted = try await fixture.archive.resume(); XCTAssertEqual(promoted, 0)
                for record in [old.file, new.file] {
                    let remote = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                    XCTAssertNil(remote)
                }
            }
        }
    }

    // Catches throwing away a still-valid raw-source ZIP merely because ordinary media grouping changed.
    func testGroupingRetainsTheAuthenticatedCacheWithoutNewFiles() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
        let items = [try await sourceFactsPhoto(fixture, name: "first.jpg"), try await sourceFactsPhoto(fixture, name: "second.jpg")]
        defer { items.forEach { try? $0.discard() } }
        let id = UUID()
        try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .media,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        try await mode(store, fixture, id, items, from: .media, to: .archive)
        try await mode(store, fixture, id, items, from: .archive, to: .media)
        let before = try await sourceFactsLoad(store), count = try recordCount(fixture)
        do {
            try await store.updateItems(preparationID: id, previousIDs: items.map(\.id), previousGrouping: false,
                previousPresentation: .media, orderedIDs: items.map(\.id), isGrouped: true, presentation: .media, target: fixture.target)
        } catch { return XCTFail("Inactive Archive cache must permit grouping: \(error)") }
        let grouped = try await sourceFactsLoad(store)
        XCTAssertTrue(grouped.isGrouped); XCTAssertEqual(grouped.archive, before.archive)
        XCTAssertEqual(grouped.schemaVersion, 16); XCTAssertEqual(try recordCount(fixture), count)
        let bundle = try await store.restoreBundle(draft: grouped); try bundle.discard()
    }

    // Catches refusing a canonical video-cover edit, dropping its ZIP cache, or adding another ZIP instead of only the cover.
    func testCoverReplacementKeepsTheRawSourceArchive() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
        let source = fixture.root.appendingPathComponent("video.mov"), image = fixture.root.appendingPathComponent("cover.jpg")
        try await writeUploadVideoFixture(source); try writeUploadVideoCoverFixture(image)
        let video = try await TelegramUploadFileIO.stage(source, mode: .video)
        let cover = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        let photo = try await sourceFactsPhoto(fixture, name: "second.jpg")
        let items = [TelegramUploadBatchItem(id: video.id, file: video, sourceFacts: try sourceFacts(video, mime: "video/mov")), photo]
        defer { items.forEach { try? $0.discard() }; try? TelegramUploadFileIO.discard(cover.imageFile) }
        let id = UUID()
        try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .media,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        try await mode(store, fixture, id, items, from: .media, to: .archive)
        let active = try await sourceFactsLoad(store), activeCount = try recordCount(fixture)
        do {
            try await store.replaceVideoCover(preparationID: id, itemID: video.id, file: video, target: fixture.target, cover: cover)
            XCTFail("Active Archive must refuse a cover edit before capture")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        let unchanged = try await sourceFactsLoad(store); XCTAssertEqual(unchanged, active)
        XCTAssertEqual(try recordCount(fixture), activeCount)
        try await mode(store, fixture, id, items, from: .archive, to: .media)
        let before = try await sourceFactsLoad(store), count = try recordCount(fixture)
        do {
            try await store.replaceVideoCover(preparationID: id, itemID: video.id, file: video, target: fixture.target, cover: cover)
        } catch { return XCTFail("Inactive Archive cache must permit a video cover: \(error)") }
        let changed = try await sourceFactsLoad(store)
        XCTAssertEqual(changed.archive, before.archive); XCTAssertEqual(changed.items[0].file, before.items[0].file)
        XCTAssertEqual(changed.items[0].videoCover?.file.plaintextSHA256, cover.sha256)
        XCTAssertEqual(try recordCount(fixture), count + 1)
        try await store.replaceVideoCover(preparationID: id, itemID: video.id, file: video, target: fixture.target, cover: cover)
        XCTAssertEqual(try recordCount(fixture), count + 1)
        let bundle = try await store.restoreBundle(draft: changed)
        XCTAssertEqual(bundle.items[0].file.videoCover?.sha256, cover.sha256); XCTAssertNotNil(bundle.archive)
        try bundle.discard()
    }

    private func mode(_ store: TelegramPendingUploadSession, _ fixture: SourceFactsTestArchive, _ id: UUID,
                      _ items: [TelegramUploadBatchItem], from: TelegramUploadPresentation, to: TelegramUploadPresentation) async throws {
        try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: from,
            previousGrouping: false, presentation: to, isGrouped: false, target: fixture.target)
    }

    private func recordCount(_ fixture: SourceFactsTestArchive) throws -> Int {
        let rows = try fixture.database.execute("SELECT count(DISTINCT object) FROM \"\(fixture.database.schema)\".archive_file_events")
        return try XCTUnwrap(Int(try XCTUnwrap(rows.first?.first))) + fixture.localRecords().count
    }

    private func ready(_ controller: TelegramUploadController) async throws {
        for _ in 0..<500 where !controller.canSend && !controller.canRetryRecovery { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(controller.canSend, "Visible preparation must be durably confirmed")
        XCTAssertFalse(controller.canRetryRecovery)
    }
}

@MainActor private final class ArchiveEditACKRepository: TelegramPendingUploadRepository {
    let base: TelegramPostboxPendingUploadRepository
    var accountID: Int64 { base.accountID }
    var failNextSaveACK = false
    init(_ base: TelegramPostboxPendingUploadRepository) { self.base = base }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        base.load(chatID: chatID, completion: completion)
    }
    func save(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID?, completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        let loseACK = failNextSaveACK; failNextSaveACK = false
        base.save(draft, expectedRevision: expectedRevision) { result in
            if loseACK, case .success = result { completion(.failure(.unavailable)) }
            else { completion(result) }
        }
    }
    func loadArchiveIntent(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveIntent?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        base.loadArchiveIntent(chatID: chatID, completion: completion)
    }
    func retainArchiveIntent(_ intent: TelegramPendingUploadArchiveIntent, chatID: Int64, admission: TelegramPendingUploadArchiveAdmission,
                             completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        base.retainArchiveIntent(intent, chatID: chatID, admission: admission, completion: completion)
    }
    func loadArchiveCapture(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveCapture?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        base.loadArchiveCapture(chatID: chatID, completion: completion)
    }
    func retainArchiveCapture(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID, admission: TelegramPendingUploadArchiveAdmission,
                              completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        base.retainArchiveCapture(draft, expectedRevision: expectedRevision, admission: admission, completion: completion)
    }
    func installArchive(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID, admission: TelegramPendingUploadArchiveAdmission,
                        completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        base.installArchive(draft, expectedRevision: expectedRevision, admission: admission, completion: completion)
    }
}

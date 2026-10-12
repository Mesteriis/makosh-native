import XCTest
import Foundation
import MakoshCore
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadArchiveBundleTests: TelegramSourceFactsIntegrationTestCase {
    // Catches dropping raw photo originals/ZIP or recapturing local resources after encrypted restart.
    func testWholeBundleReopensFromLocalAndS3WithoutRecapture() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let items = [try await sourceFactsPhoto(fixture),
                         try await sourceFactsDocument(fixture, name: ".hidden.txt", text: "Synthetic hidden source")]
            defer { items.forEach { try? $0.discard() } }
            let preparedBytes = try items.map { try Data(contentsOf: $0.file.url) }
            let originalBytes = try items.map { try $0.originalFile.map { try Data(contentsOf: $0.url) } }
            var saved: TelegramPendingUploadDraft?, zipBytes = Data()
            weak var previous: Postbox?
            do {
                let box = try await sourceFactsOpen(fixture.postboxPath); previous = box
                let (draft, zip) = try await archivedDraft(fixture, box: box, items: items)
                defer { try? TelegramUploadFileIO.discard(zip.file) }
                saved = draft; zipBytes = try Data(contentsOf: zip.file.url)
                try (await sourceFactsValue(archiveBundleInstall(box, draft: draft))).get()
                for item in items { try item.discard() }
                for name in ["photo.jpg", ".hidden.txt"] { try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(name)) }
            }
            for _ in 0..<100 where previous != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(previous)
            let box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
            let draft = try await sourceFactsLoad(store)
            XCTAssertEqual(draft, saved); XCTAssertEqual(draft.schemaVersion, 16)
            let records = draft.items.flatMap { [$0.file] + ($0.originalFile.map { [$0] } ?? []) } + [try XCTUnwrap(draft.archive?.file)]
            XCTAssertTrue(records.allSatisfy { $0.state == (enabled ? .stored : .local) })
            let before = try fixture.localRecords(), events = try fileEvents(fixture)
            let bundle: TelegramRecoveredUploadBundle
            do { bundle = try await store.restoreBundle(draft: draft) }
            catch { return XCTFail("A complete authenticated bundle was refused: \(error)") }
            defer { try? bundle.discard() }
            let zip = try XCTUnwrap(bundle.archive)
            XCTAssertEqual(bundle.items.map(\.id), items.map(\.id))
            XCTAssertEqual(bundle.items.map(\.sourceFacts), items.map(\.sourceFacts))
            XCTAssertEqual(try bundle.items.map { try Data(contentsOf: $0.file.url) }, preparedBytes)
            XCTAssertEqual(try bundle.items.map { try $0.originalFile.map { try Data(contentsOf: $0.url) } }, originalBytes)
            XCTAssertEqual(try Data(contentsOf: zip.file.url), zipBytes)
            XCTAssertEqual(zip.members.map(\.itemID), items.map(\.id))
            XCTAssertEqual(zip.members.map(\.entryName), ["photo.jpg", ".hidden.txt"])
            XCTAssertEqual(try fixture.localRecords(), before); XCTAssertEqual(try fileEvents(fixture), events)
            let paths = bundle.items.flatMap { [$0.file.directory] + ($0.originalFile.map { [$0.directory] } ?? []) } + [zip.file.directory]
            try bundle.discard()
            XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            let reopened = try await store.restoreBundle(draft: draft)
            defer { try? reopened.discard() }
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.archive?.file.url)), zipBytes)
            if !enabled {
                XCTAssertEqual(events, [["0"]])
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                let resumed = try await fixture.archive.resume(); XCTAssertEqual(resumed, 0)
                for record in records {
                    let remote = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
                    XCTAssertNil(remote)
                }
                XCTAssertEqual(try fileEvents(fixture), [["0"]])
            }
        }
    }

    // Catches exporting canonical stages, then leaking them when ZIP/member authentication fails.
    func testForgedMemberNameRefusesWholeBundleAndCleansAllNewStages() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let items = [try await sourceFactsPhoto(fixture),
                     try await sourceFactsDocument(fixture, name: "later.txt", text: "Synthetic later source")]
        defer { items.forEach { try? $0.discard() } }
        let (draft, zip) = try await archivedDraft(fixture, box: box, items: items)
        defer { try? TelegramUploadFileIO.discard(zip.file) }
        let saved = try XCTUnwrap(draft.archive)
        let changed = TelegramPendingUploadArchive(id: saved.id, file: saved.file,
            members: [.init(itemID: items[0].id, entryName: "different.jpg"), saved.members[1]])
        let forged = try replacingArchive(draft, changed)
        XCTAssertTrue(forged.isValid, "Descriptor syntax alone cannot authenticate ZIP members")
        let stages = try ownedDirectories(), local = try fixture.localRecords(), events = try fileEvents(fixture)
        do {
            let unexpected = try await fixture.session(box).restoreBundle(draft: forged)
            try? unexpected.discard(); XCTFail("A different ZIP member name was restored")
        } catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
        XCTAssertEqual(try ownedDirectories(), stages)
        XCTAssertEqual(try fixture.localRecords(), local); XCTAssertEqual(try fileEvents(fixture), events)
    }

    // Catches legacy array restoration silently omitting the new archive resource.
    func testArrayOnlyRestorationRefusesAnArchiveDraft() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "first"),
                     try await sourceFactsDocument(fixture, name: "second.txt", text: "second")]
        defer { items.forEach { try? $0.discard() } }
        let (draft, zip) = try await archivedDraft(fixture, box: box, items: items)
        defer { try? TelegramUploadFileIO.discard(zip.file) }
        let stages = try ownedDirectories()
        do {
            let unexpected = try await fixture.session(box).restoreItems(draft: draft)
            unexpected.forEach { try? $0.discard() }; XCTFail("Array-only restoration dropped ZIP")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .incompatibleData) }
        XCTAssertEqual(try ownedDirectories(), stages)
    }

    // Catches restoration doing exports when the owning operation was already cancelled.
    func testPreCancelledBundleDoesNotCreateStages() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "first"),
                     try await sourceFactsDocument(fixture, name: "second.txt", text: "second")]
        defer { items.forEach { try? $0.discard() } }
        let (draft, zip) = try await archivedDraft(fixture, box: box, items: items)
        defer { try? TelegramUploadFileIO.discard(zip.file) }
        let stages = try ownedDirectories(), store = fixture.session(box)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.restoreBundle(draft: draft)
        }
        do { let unexpected = try await operation.value; try? unexpected.discard(); XCTFail("Cancelled bundle restored") }
        catch { XCTAssertTrue(error is CancellationError, "A pre-cancelled restore must report cancellation") }
        XCTAssertEqual(try ownedDirectories(), stages)
    }

    private func archivedDraft(_ fixture: SourceFactsTestArchive, box: Postbox,
                               items: [TelegramUploadBatchItem]) async throws -> (TelegramPendingUploadDraft, TelegramUploadArchiveIO.Archive) {
        let store = fixture.session(box), preparationID = UUID()
        try await store.prepare(preparationID: preparationID, items: items, isGrouped: false, presentation: .file,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        let current = try await sourceFactsLoad(store)
        let sources = items.map { TelegramUploadArchiveIO.Source(itemID: $0.id, file: $0.rawSource) }
        let zip = try await TelegramUploadArchiveIO.prepare(sources)
        do {
            let file = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(zip, sources: sources,
                archiveID: zip.file.id, accountID: 1, chatID: 42, preparationID: preparationID)
            let descriptor = TelegramPendingUploadArchive(id: zip.file.id, file: file,
                members: zip.members.map { .init(itemID: $0.itemID, entryName: $0.entryName) })
            return (try replacingArchive(current, descriptor), zip)
        } catch { try? TelegramUploadFileIO.discard(zip.file); throw error }
    }

    private func replacingArchive(_ draft: TelegramPendingUploadDraft, _ archive: TelegramPendingUploadArchive) throws -> TelegramPendingUploadDraft {
        try .init(id: draft.id, accountID: draft.accountID, chatID: draft.chatID, title: draft.title,
            captionInput: draft.captionInput, originalDraft: draft.originalDraft, replyTarget: draft.replyTarget,
            items: draft.items, isGrouped: false, presentation: .archive, archive: archive)
    }

    private func ownedDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("makosh-upload-") }.map(\.path))
    }

    private func fileEvents(_ fixture: SourceFactsTestArchive) throws -> [[String]] {
        try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events")
    }
}

// The engine runs transaction closures on its own queue, independently of the test's MainActor.
private nonisolated func archiveBundleInstall(_ box: Postbox, draft: TelegramPendingUploadDraft)
    -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    box.transaction { transaction in
        switch telegramPendingUploadRead(transaction: transaction, accountID: 1, chatID: 42) {
        case let .success(previous):
            return telegramPendingUploadWrite(transaction: transaction, accountID: 1,
                draft: draft, expectedRevision: previous?.revision)
        case let .failure(error): return .failure(error)
        }
    }
}

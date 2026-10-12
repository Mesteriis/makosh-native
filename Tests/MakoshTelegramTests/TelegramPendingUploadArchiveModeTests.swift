import XCTest
import Foundation
import MakoshCore
import Postbox
import TelegramCore
import SwiftSignalKit
@testable import MakoshTelegram

private nonisolated func archiveModeNativeMessages(_ box: Postbox, ids: [TelegramUploadQueueID]) -> Signal<[Message], NoError> {
    box.transaction { transaction in ids.compactMap { transaction.getMessage($0.nativeID) } }
}

@MainActor final class TelegramPendingUploadArchiveModeTests: TelegramSourceFactsIntegrationTestCase {
    // Catches a visible mode switch without its durable ZIP, or submitting the cached ZIP after selecting File/Media.
    func testControllerCreatesArchiveSwitchesModesAndSubmitsTheSelectedRepresentation() async throws {
        for finalMode in [TelegramUploadPresentation.archive, .file, .media] {
            let fixture = try await sourceFactsArchive(accountID: -1), box = try await sourceFactsOpen(fixture.postboxPath)
            let originals = [try await sourceFactsPhoto(fixture, name: "first.jpg"),
                             try await sourceFactsPhoto(fixture, name: "second.jpg")]
            defer { originals.forEach { try? $0.discard() } }
            let store = fixture.session(box), controller = TelegramUploadController()
            controller.bind(provider: TelegramSyntheticUploadProvider(postbox: box), recoveryStore: store, requiresRecovery: true)
            defer { controller.clear() }
            controller.prepare(sources: ["first.jpg", "second.jpg"].map {
                .init(source: fixture.root.appendingPathComponent($0), mode: .photo)
            }, isGrouped: true, target: fixture.target, captionInput: .empty)
            for _ in 0..<500 where !controller.canEditItems { try await Task.sleep(for: .milliseconds(10)) }
            let id = try XCTUnwrap(controller.preparationContextID)
            guard controller.updatePresentation(.archive, contextID: id, revision: controller.itemsRevision) else {
                XCTFail("The ordinary picker must permit Archive"); continue
            }
            for _ in 0..<500 where !controller.canSend && !controller.canRetryRecovery { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(controller.canSend); XCTAssertEqual(controller.presentation, .archive)
            XCTAssertEqual(controller.presentedItems.count, 1)
            XCTAssertEqual(controller.file?.name, "Telegram Archive.zip")
            let archived = try await sourceFactsLoad(store), descriptor = try XCTUnwrap(archived.archive)
            let count = try recordCount(fixture)
            if finalMode != .archive {
                guard controller.updatePresentation(finalMode, contextID: id, revision: controller.itemsRevision) else {
                    XCTFail("Archive must switch back to File/Media"); continue
                }
                for _ in 0..<500 where !controller.canSend && !controller.canRetryRecovery { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(controller.canSend); XCTAssertEqual(controller.presentedItems.count, 2)
                controller.bind(provider: nil)
                controller.bind(provider: TelegramSyntheticUploadProvider(postbox: box), recoveryStore: store, requiresRecovery: true)
                let stored = try await sourceFactsLoad(store), recovered = try await store.restoreBundle(draft: stored)
                guard controller.restore(draft: stored, bundle: recovered, target: fixture.target,
                                         restorationEpoch: controller.recoveryRestoreEpoch) else {
                    try recovered.discard(); XCTFail("Inactive ZIP cache must restore in its selected mode"); continue
                }
                XCTAssertTrue(controller.canSend); XCTAssertEqual(controller.presentation, finalMode)
            }
            controller.send()
            for _ in 0..<500 where controller.phase != .queued(nil) && controller.phase != .uncertain && controller.phase != .rejected {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(controller.phase, .queued(nil))
            XCTAssertEqual(controller.messageIDs.count, finalMode == .archive ? 1 : 2)
            let accepted = try await sourceFactsLoad(store)
            XCTAssertEqual(accepted.presentation, finalMode); XCTAssertEqual(accepted.archive, descriptor)
            XCTAssertEqual(try recordCount(fixture), count)
            guard case let .acceptedBatch(ids) = accepted.disposition else { return XCTFail("Native acceptance required") }
            let messages = try await sourceFactsValue(archiveModeNativeMessages(box, ids: ids))
            XCTAssertEqual(messages.count, finalMode == .archive ? 1 : 2)
            if finalMode == .media {
                XCTAssertTrue(messages.allSatisfy { $0.media.first is TelegramMediaImage })
            } else {
                let files = messages.compactMap { $0.media.first as? TelegramMediaFile }
                XCTAssertEqual(files.count, messages.count)
                XCTAssertEqual(files.map(\.mimeType), finalMode == .archive ? ["application/zip"] : ["image/jpeg", "image/jpeg"])
                XCTAssertEqual(files.compactMap(\.fileName), finalMode == .archive ? ["Telegram Archive.zip"] : ["first.jpg", "second.jpg"])
            }
        }
    }

    // Catches silently normalizing an invalid grouped Archive request after creating immutable ZIP records.
    func testGroupedArchiveAndStaleModeRequestsCreateNoNewCopies() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
        let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "First"),
                     try await sourceFactsDocument(fixture, name: "second.txt", text: "Second")]
        defer { items.forEach { try? $0.discard() } }
        let id = UUID()
        try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
            target: fixture.target, captionInput: .empty, originalDraft: nil)
        let before = try await sourceFactsLoad(store), count = try recordCount(fixture)
        for (previous, grouped) in [(TelegramUploadPresentation.file, true), (.media, false)] {
            do {
                try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: previous,
                    previousGrouping: false, presentation: .archive, isGrouped: grouped, target: fixture.target)
                XCTFail("Invalid mode admission must refuse")
            } catch let error as TelegramPendingUploadPersistenceError {
                XCTAssertEqual(error, grouped ? .incompatibleData : .conflict)
            }
            let unchanged = try await sourceFactsLoad(store); XCTAssertEqual(unchanged, before)
            XCTAssertEqual(try recordCount(fixture), count)
        }
    }

    // Catches depending on the picker stages, recapturing members, or uploading a ZIP while S3 is OFF.
    func testArchiveModeBuildsFromDurableOriginalsAfterPickerStagesAreRemoved() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let box = try await sourceFactsOpen(fixture.postboxPath), store = fixture.session(box)
            let first = try await sourceFactsDocument(fixture, name: "first.txt", text: "First raw source")
            let second = try await sourceFactsDocument(fixture, name: "second.txt", text: "Second raw source")
            let items = [first, second]
            defer { items.forEach { try? $0.discard() } }
            let input = try TelegramComposerInput(formattedText: .init(text: "  ZIP 😀  "), selection: .init(location: 2, length: 3))
            let id = UUID()
            try await store.prepare(preparationID: id, items: items, isGrouped: false, presentation: .file,
                target: fixture.target, captionInput: input, originalDraft: nil)
            let before = try await sourceFactsLoad(store), records = try recordCount(fixture)
            for item in items { try item.discard() }
            try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            let after = try await sourceFactsLoad(store)
            XCTAssertEqual(after.schemaVersion, 18); XCTAssertEqual(after.presentation, .archive)
            XCTAssertEqual(after.id, before.id); XCTAssertEqual(after.captionInput, input)
            XCTAssertEqual(after.items, before.items); XCTAssertEqual(after.originalDraft, before.originalDraft)
            XCTAssertFalse(after.isGrouped); XCTAssertFalse(after.captionAboveMedia); XCTAssertFalse(after.mediaSpoiler)
            let descriptor = try XCTUnwrap(after.archive)
            XCTAssertEqual(descriptor.members.map(\.entryName), ["first.txt", "second.txt"])
            XCTAssertEqual(try recordCount(fixture), records + 1)
            XCTAssertEqual(descriptor.file.state, enabled ? .stored : .local)
            let bundle = try await store.restoreBundle(draft: after)
            defer { try? bundle.discard() }
            XCTAssertEqual(try Data(contentsOf: bundle.items[0].rawSource.url), Data("First raw source".utf8))
            XCTAssertEqual(try Data(contentsOf: bundle.items[1].rawSource.url), Data("Second raw source".utf8))
            XCTAssertNotNil(bundle.archive)
            try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .file,
                previousGrouping: false, presentation: .archive, isGrouped: false, target: fixture.target)
            let replay = try await sourceFactsLoad(store); XCTAssertEqual(replay, after)
            XCTAssertEqual(try recordCount(fixture), records + 1)
            if !enabled {
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                let promoted = try await fixture.archive.resume(); XCTAssertEqual(promoted, 0)
                let remote = try await S3ObjectStore(configuration: fixture.configuration).head(key: descriptor.file.objectKey)
                XCTAssertNil(remote)
            }
        }
    }

    // Catches losing the ZIP cache, raw editor state or original media when switching through all three modes.
    func testModeRoundTripRetainsTheSameArchiveWithoutNewFileRecords() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let items = [try await sourceFactsPhoto(fixture, name: "first.jpg"),
                     try await sourceFactsPhoto(fixture, name: "second.jpg")]
        defer { items.forEach { try? $0.discard() } }
        let store = fixture.session(box), id = UUID()
        let input = try TelegramComposerInput(formattedText: .init(text: "Raw caption 😀"), selection: .init(location: 4, length: 7))
        try await store.prepare(preparationID: id, items: items, isGrouped: true, presentation: .media,
            target: fixture.target, captionInput: input, captionAboveMedia: true, mediaSpoiler: true, originalDraft: nil)
        try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: .media,
            previousGrouping: true, presentation: .archive, isGrouped: false, target: fixture.target)
        let archived = try await sourceFactsLoad(store), count = try recordCount(fixture)
        let descriptor = try XCTUnwrap(archived.archive)
        let modes: [(TelegramUploadPresentation, TelegramUploadPresentation)] = [(.archive, .file), (.file, .media), (.media, .archive)]
        for (old, new) in modes {
            try await store.updatePresentation(preparationID: id, orderedIDs: items.map(\.id), previousPresentation: old,
                previousGrouping: false, presentation: new, isGrouped: false, target: fixture.target)
            let changed = try await sourceFactsLoad(store)
            XCTAssertEqual(changed.schemaVersion, 18); XCTAssertEqual(changed.presentation, new)
            XCTAssertEqual(changed.items, archived.items); XCTAssertEqual(changed.archive, descriptor)
            XCTAssertEqual(changed.captionInput, input)
            XCTAssertFalse(changed.captionAboveMedia); XCTAssertFalse(changed.mediaSpoiler)
            XCTAssertEqual(try recordCount(fixture), count)
            let recovered = try await store.restoreBundle(draft: changed)
            XCTAssertNotNil(recovered.archive); try recovered.discard()
        }
    }

    private func recordCount(_ fixture: SourceFactsTestArchive) throws -> Int {
        let rows = try fixture.database.execute("SELECT count(DISTINCT object) FROM \"\(fixture.database.schema)\".archive_file_events")
        return try XCTUnwrap(Int(try XCTUnwrap(rows.first?.first))) + fixture.localRecords().count
    }
}

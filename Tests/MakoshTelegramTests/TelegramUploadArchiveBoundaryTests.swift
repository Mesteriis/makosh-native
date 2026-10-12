import XCTest
import Foundation
@testable import MakoshTelegram

@MainActor final class TelegramUploadArchiveBoundaryTests: TelegramSourceFactsIntegrationTestCase {
    // Catches interpreting unprojected originals as multiple Archive send messages.
    func testOrdinaryBatchPlanCannotSendRawItemsAsArchive() async throws {
        let fixture = try await sourceFactsArchive()
        let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "first"),
                     try await sourceFactsDocument(fixture, name: "second.txt", text: "second")]
        defer { items.forEach { try? $0.discard() } }
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: items, isGrouped: false,
            caption: TelegramFormattedText(text: "Synthetic caption"), presentation: .archive))
    }

    // Catches generic preparation copying originals before discovering the missing archive descriptor.
    func testOrdinaryPrepareRefusesArchiveBeforeImmutableCopies() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let items = [try await sourceFactsDocument(fixture, name: "first.txt", text: "first"),
                     try await sourceFactsDocument(fixture, name: "second.txt", text: "second")]
        defer { items.forEach { try? $0.discard() } }
        do {
            try await fixture.session(box).prepare(preparationID: UUID(), items: items, isGrouped: false, presentation: .archive,
                target: fixture.target, captionInput: .empty, originalDraft: nil)
            XCTFail("Archive preparation requires a verified whole bundle")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .incompatibleData) }
        XCTAssertEqual(try fixture.localRecords(), [])
        XCTAssertEqual(try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events"), [["0"]])
        let pointer = try await fixture.session(box).load(chatID: 42); XCTAssertNil(pointer)
    }

    // Catches mutating preview mode/revisions before the generic store refuses Archive without a ZIP.
    func testGenericPresentationSwitchCannotPartiallyEnterArchive() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let fixtures = [try await sourceFactsPhoto(fixture, name: "first.jpg"),
                        try await sourceFactsPhoto(fixture, name: "second.jpg")]
        defer { fixtures.forEach { try? $0.discard() } }
        let store = fixture.session(box), controller = TelegramUploadController()
        controller.bind(provider: ArchiveBoundaryProvider(), recoveryStore: store, requiresRecovery: true)
        defer { controller.clear() }
        controller.prepare(sources: ["first.jpg", "second.jpg"].map {
            .init(source: fixture.root.appendingPathComponent($0), mode: .file)
        }, isGrouped: false, target: fixture.target, captionInput: .empty)
        for _ in 0..<500 where !controller.canEditItems { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready); XCTAssertTrue(controller.canSwitchPresentation)
        let id = try XCTUnwrap(controller.preparationContextID), revision = controller.itemsRevision
        let before = try await sourceFactsLoad(store), paths = controller.items.map(\.file.url)
        XCTAssertFalse(controller.updatePresentation(.archive, contextID: id, revision: revision))
        XCTAssertEqual(controller.presentation, .file); XCTAssertEqual(controller.itemsRevision, revision)
        XCTAssertEqual(controller.items.map(\.file.url), paths)
        let after = try await sourceFactsLoad(store)
        XCTAssertEqual(after, before)
    }
}

@MainActor private final class ArchiveBoundaryProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        receive(.rejected); return ArchiveBoundaryLease()
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
                captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        receive(.rejected); return ArchiveBoundaryLease()
    }
}
@MainActor private final class ArchiveBoundaryLease: TelegramUploadLease { func stop() {} }

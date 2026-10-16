import XCTest
import Foundation
import MakoshCore
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramArchiveGenerationControllerTests: TelegramSourceFactsIntegrationTestCase {
    // Catches a late ZIP callback reviving a cancelled preparation after the picker has rebound.
    func testCancellationWhileArchiveInstallIsHeldPersistsOnlyTheOriginalCancellation() async throws {
        try await heldArchive(cancel: true)
    }

    // Catches a late ZIP callback replacing another chat's files/caption or losing the old chat's latest input.
    func testRebindWhileArchiveInstallIsHeldPreservesBothPreparations() async throws {
        try await heldArchive(cancel: false)
    }

    private func heldArchive(cancel: Bool) async throws {
        for enabled in [false, true] {
            for committed in [false, true] {
                let fixture = try await sourceFactsArchive(accountID: -1)
                try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
                let box = try await sourceFactsOpen(fixture.postboxPath)
                let repository = ArchiveGenerationGateRepository(box, accountID: -1)
                let originalStore = TelegramPendingUploadSession(repository: repository,
                    files: { TelegramPendingUploadFiles(repository: fixture.archive) })
                let otherStore = fixture.session(box)
                let originalItems = [try await sourceFactsDocument(fixture, name: "first.txt", text: "First raw source"),
                                     try await sourceFactsDocument(fixture, name: "second.txt", text: "Second raw source")]
                let nextItem = try await sourceFactsDocument(fixture, name: "next.txt", text: "Other chat source")
                defer { (originalItems + [nextItem]).forEach { try? $0.discard() } }
                let originalID = UUID(), nextID = UUID()
                let nextTarget = TelegramUploadTarget(accountID: -1, chatID: 43, title: "Other synthetic chat")
                let nextInput = try TelegramComposerInput(formattedText: .init(text: "Other chat caption"))
                try await originalStore.prepare(preparationID: originalID, items: originalItems, isGrouped: false,
                    presentation: .file, target: fixture.target, captionInput: .empty, originalDraft: nil)
                try await otherStore.prepare(preparationID: nextID, items: [nextItem], isGrouped: false,
                    presentation: .file, target: nextTarget, captionInput: nextInput, originalDraft: nil)
                let nextLoaded = try await otherStore.load(chatID: 43)
                let nextDraft = try XCTUnwrap(nextLoaded)
                let originalDraft = try await sourceFactsLoad(originalStore)
                let controller = TelegramUploadController()
                controller.bind(provider: TelegramSyntheticUploadProvider(postbox: box), recoveryStore: originalStore, requiresRecovery: true)
                let originalBundle = try await originalStore.restoreBundle(draft: originalDraft)
                guard await controller.restore(draft: originalDraft, bundle: originalBundle, target: fixture.target,
                                         restorationEpoch: controller.recoveryRestoreEpoch) else {
                    try originalBundle.discard(); return XCTFail("Original picker must restore")
                }
                defer { controller.clear(); repository.release() }
                repository.holdAfterCommit = committed
                repository.holdNextInstall = true
                XCTAssertTrue(controller.updatePresentation(.archive, contextID: originalID, revision: controller.itemsRevision))
                try await eventually { repository.isHeld }
                let descriptor = try XCTUnwrap(repository.candidate?.archive)
                let latestInput = try TelegramComposerInput(formattedText: .init(text: "Latest original 😀",
                    entities: [.init(offset: 16, length: 2, kind: .bold)]), selection: .init(location: 16, length: 2))
                XCTAssertTrue(controller.updateCaptionInput(latestInput, contextID: controller.captionContextID))
                XCTAssertFalse(controller.canSend)
                if cancel { controller.cancelPreparation(); XCTAssertEqual(controller.phase, .cancelled) }

                controller.bind(provider: TelegramSyntheticUploadProvider(postbox: box), recoveryStore: otherStore, requiresRecovery: true)
                let nextBundle = try await otherStore.restoreBundle(draft: nextDraft)
                guard await controller.restore(draft: nextDraft, bundle: nextBundle, target: nextTarget,
                                         restorationEpoch: controller.recoveryRestoreEpoch) else {
                    try nextBundle.discard(); return XCTFail("The other chat must restore while the old ZIP callback is held")
                }
                let nextRevision = controller.itemsRevision, nextEpoch = controller.recoveryRestoreEpoch
                let records = try recordCount(fixture)
                repository.release()
                try await eventually { controller.detachedRecoveryStatus == nil && !controller.isCancellationBusy }
                XCTAssertFalse(controller.canRetryDetachedRecovery)
                XCTAssertEqual(controller.preparationContextID, nextID)
                XCTAssertEqual(controller.target, nextTarget)
                XCTAssertEqual(controller.captionInput, nextInput)
                XCTAssertEqual(controller.itemsRevision, nextRevision)
                XCTAssertNotEqual(controller.recoveryRestoreEpoch, nextEpoch, "Completing an old write must invalidate stale restore observations")
                XCTAssertEqual(controller.presentation, .file)
                XCTAssertEqual(controller.presentedItems.map(\.file.name), ["next.txt"])
                let visible = try XCTUnwrap(controller.presentedItems.first?.file)
                XCTAssertEqual(try Data(contentsOf: visible.url), Data("Other chat source".utf8),
                    "Old cleanup must leave the new chat's staged bytes readable")
                XCTAssertEqual(controller.phase, .ready); XCTAssertTrue(controller.canSend)
                let nextSaved = try await otherStore.load(chatID: 43)
                XCTAssertEqual(nextSaved, nextDraft, "An old completion must not write the new chat's pointer")
                let originalSaved = try await sourceFactsLoad(originalStore)
                XCTAssertEqual(originalSaved.id, originalID)
                XCTAssertEqual(originalSaved.archive, descriptor)
                XCTAssertEqual(originalSaved.captionInput, latestInput)
                XCTAssertEqual(originalSaved.disposition, cancel ? .cancelled : .prepared)
                XCTAssertEqual(try recordCount(fixture), records, "Late completion and cancellation must not recapture files")
                XCTAssertEqual(descriptor.file.state, enabled ? .stored : .local)
                if !enabled {
                    try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
                    let promoted = try await fixture.archive.resume(); XCTAssertEqual(promoted, 0)
                    let remote = try await S3ObjectStore(configuration: fixture.configuration).head(key: descriptor.file.objectKey)
                    XCTAssertNil(remote, "The old OFF preparation must remain local after enabling S3")
                }
            }
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected held Archive operation to settle")
        throw TelegramPendingUploadPersistenceError.unavailable
    }

    private func recordCount(_ fixture: SourceFactsTestArchive) throws -> Int {
        let rows = try fixture.database.execute("SELECT count(DISTINCT object) FROM \"\(fixture.database.schema)\".archive_file_events")
        return try XCTUnwrap(Int(try XCTUnwrap(rows.first?.first))) + fixture.localRecords().count
    }
}

// Hold dispatch or delivery at the native install boundary; file storage,
// reservations, retention and every pointer mutation use the real repositories.
@MainActor private final class ArchiveGenerationGateRepository: TelegramPendingUploadRepository {
    let accountID: Int64
    let base: TelegramPostboxPendingUploadRepository
    var holdNextInstall = false, holdAfterCommit = false
    private(set) var candidate: TelegramPendingUploadDraft?
    private var held: (() -> Void)?
    var isHeld: Bool { held != nil }
    init(_ box: Postbox, accountID: Int64) {
        self.accountID = accountID; base = .init(postbox: box, accountID: accountID)
    }
    func release() { let operation = held; held = nil; operation?() }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        base.load(chatID: chatID, completion: completion)
    }
    func save(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID?, completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        base.save(draft, expectedRevision: expectedRevision, completion: completion)
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
        guard holdNextInstall else {
            base.installArchive(draft, expectedRevision: expectedRevision, admission: admission, completion: completion); return
        }
        holdNextInstall = false; candidate = draft
        if holdAfterCommit {
            base.installArchive(draft, expectedRevision: expectedRevision, admission: admission) { result in
                self.held = { completion(result) }
            }
        } else {
            held = { self.base.installArchive(draft, expectedRevision: expectedRevision, admission: admission, completion: completion) }
        }
    }
}

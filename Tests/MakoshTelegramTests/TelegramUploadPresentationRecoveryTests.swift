import XCTest
import Foundation
import MakoshCore
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramUploadPresentationRecoveryTests: XCTestCase {
    // Catches a stale text role after grouping/mode/member changes, or resetting rich input with it.
    func testPlaceholderChangesPreserveRichInputAcrossEditsAndRestore() async throws {
        let fixture = try await fixture(), repository = Repository(fixture.draft), store = session(repository)
        let controller = TelegramUploadController()
        controller.bind(provider: Provider(), recoveryStore: store, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        defer { controller.clear() }
        let context = controller.captionContextID, preparation = fixture.draft.id
        let input = try TelegramComposerInput(formattedText: .init(text: "Exact 😀", entities: [.init(offset: 6, length: 2, kind: .bold)]),
            selection: .init(location: 6, length: 2))
        XCTAssertTrue(controller.updateCaptionInput(input, contextID: context))
        XCTAssertTrue(controller.usesCaptionPlaceholder)
        XCTAssertTrue(controller.updateGrouping(false, contextID: preparation, revision: controller.itemsRevision))
        await drain()
        XCTAssertFalse(controller.usesCaptionPlaceholder)
        XCTAssertTrue(controller.updateGrouping(true, contextID: preparation, revision: controller.itemsRevision))
        await drain()
        XCTAssertTrue(controller.usesCaptionPlaceholder)
        XCTAssertTrue(controller.updatePresentation(.file, contextID: preparation, revision: controller.itemsRevision))
        await drain()
        XCTAssertFalse(controller.usesCaptionPlaceholder, "Grouped File mode still has two individual preview rows")
        XCTAssertEqual(controller.captionInput, input); XCTAssertEqual(controller.captionContextID, context)
        XCTAssertTrue(controller.removeItem(id: fixture.items[1].id, contextID: preparation, revision: controller.itemsRevision))
        await drain()
        XCTAssertTrue(controller.usesCaptionPlaceholder)
        let saved = try XCTUnwrap(repository.value)
        XCTAssertEqual(saved.captionInput, input); XCTAssertEqual(saved.id, preparation)
        let reopened = TelegramUploadController()
        reopened.bind(provider: Provider(), recoveryStore: store, requiresRecovery: true)
        defer { reopened.clear() }
        XCTAssertTrue(reopened.restore(draft: saved, items: [fixture.items[0]], target: target,
            restorationEpoch: reopened.recoveryRestoreEpoch))
        XCTAssertTrue(reopened.usesCaptionPlaceholder)
        XCTAssertEqual(reopened.captionInput, input); XCTAssertEqual(reopened.preparationContextID, preparation)
    }

    // Catches treating whole-list mosaic eligibility as media-option eligibility.
    func testMixedMediaKeepsCaptionAndSpoilerActionsWithExactStaleGuards() async throws {
        let fixture = try await fixture(mixed: true), controller = TelegramUploadController(), provider = Provider()
        let repository = Repository(fixture.draft), session = session(repository)
        controller.bind(provider: provider, recoveryStore: session, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        defer { controller.clear() }
        XCTAssertFalse(controller.isVisualMedia, "A mixed list must retain its ordinary list layout")
        XCTAssertFalse(controller.canGroupItems)
        let oldRevision = controller.captionRevision, context = controller.captionContextID
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: context, revision: oldRevision))
        XCTAssertFalse(controller.updateMediaSpoiler(true, contextID: context, revision: oldRevision))
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: context, revision: controller.captionRevision))
        XCTAssertFalse(controller.updateCaptionPlacement(false, contextID: UUID(), revision: controller.captionRevision))
        await drain()
        XCTAssertEqual(repository.value?.captionInput, fixture.draft.captionInput)
        XCTAssertEqual(repository.value?.captionAboveMedia, true)
        XCTAssertEqual(repository.value?.mediaSpoiler, true)
        XCTAssertTrue(controller.updateMediaSpoiler(false, contextID: context, revision: controller.captionRevision))
        await drain()
        controller.sendAsSpoiler(contextID: fixture.draft.id, revision: controller.captionRevision)
        await drain()
        XCTAssertEqual(provider.submissions.count, 1)
        XCTAssertEqual(provider.submissions.first?.items, fixture.draft.items)
        XCTAssertEqual(provider.submissions.first?.captionInput, fixture.draft.captionInput)
        XCTAssertEqual(provider.submissions.first?.captionAboveMedia, true)
        XCTAssertEqual(provider.submissions.first?.mediaSpoiler, true)
        XCTAssertFalse(controller.mediaSpoiler, "The one-shot override must not change the preview choice")
    }

    // Catches losing a failed mode write and its retry when the account binding changes.
    func testBeforeCommitModeFailureAfterRebindRetriesOnlyOriginalStore() async throws {
        try await assertDetachedRetry(commitBeforeFailure: false)
    }

    func testLostModeAcknowledgementAfterRebindReusesCommittedResources() async throws {
        try await assertDetachedRetry(commitBeforeFailure: true)
    }

    func testDetachedModeRetryCannotRewriteCancellation() async throws {
        try await assertDetachedRetry(replacement: .cancelled)
    }

    func testDetachedModeRetryCannotRewriteANewerPreparation() async throws {
        try await assertDetachedRetry(replacement: .newer)
    }

    // Catches retaining a retired original store after a failed mode is cancelled.
    func testCancelledFailedModeReleasesOriginalStoreAfterRebind() async throws {
        let fixture = try await fixture(), controller = TelegramUploadController()
        var repository: Repository? = Repository(fixture.draft)
        weak let observed = repository
        var original: TelegramPendingUploadSession? = session(try XCTUnwrap(repository))
        controller.bind(provider: Provider(), recoveryStore: original, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        repository?.holdNextWrite = true
        XCTAssertTrue(controller.updatePresentation(.file, contextID: fixture.draft.id, revision: controller.itemsRevision))
        await drain(); XCTAssertNotNil(repository?.held)
        repository?.release(commit: false); await drain()
        XCTAssertTrue(controller.canRetryRecovery)
        controller.cancelPreparation(); await drain()
        XCTAssertEqual(repository?.value?.disposition, .cancelled)
        controller.bind(provider: Provider(), recoveryStore: session(Repository(nil)), requiresRecovery: true)
        original = nil; repository = nil; await drain()
        XCTAssertNil(observed, "A cancelled mode retry must release its retired store")
        XCTAssertFalse(controller.canRetryDetachedRecovery); XCTAssertFalse(controller.canSend)
    }

    func testFilePresentationRefusesMediaOptionsAndBlocksUnconfirmedSend() async throws {
        let fixture = try await fixture(), controller = TelegramUploadController(), provider = Provider()
        let repository = Repository(fixture.draft), session = session(repository)
        controller.bind(provider: provider, recoveryStore: session, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        defer { controller.clear() }
        repository.holdNextWrite = true
        XCTAssertTrue(controller.updatePresentation(.file, contextID: fixture.draft.id, revision: controller.itemsRevision))
        await drain(); XCTAssertNotNil(repository.held)
        XCTAssertFalse(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertFalse(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        controller.send(); XCTAssertFalse(controller.canSend)
        repository.release(commit: false); await drain()
        XCTAssertTrue(controller.canRetryRecovery); XCTAssertFalse(controller.canSend)
        controller.send(); XCTAssertTrue(provider.submissions.isEmpty)
        controller.retryRecovery(); await drain()
        XCTAssertTrue(controller.canSend)
        XCTAssertEqual(repository.value?.presentation, .file)
        XCTAssertEqual(repository.value?.items, fixture.draft.items)
    }

    // The last visual removal must change the list and its mode in one CAS.
    func testRemovingLastVisualNormalizesModeAndPreservesOrderedResourcesAndOptions() async throws {
        let fixture = try await fixture(mixed: true, extraDocument: true), controller = TelegramUploadController()
        let repository = Repository(fixture.draft), store = session(repository)
        controller.bind(provider: Provider(), recoveryStore: store, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        defer { controller.clear() }
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        await drain()
        let before = try XCTUnwrap(repository.value), revision = controller.itemsRevision
        let captionRevision = controller.captionRevision, writes = repository.writes.count
        XCTAssertFalse(controller.removeItem(id: fixture.items[0].id, contextID: UUID(), revision: revision))
        XCTAssertTrue(controller.removeItem(id: fixture.items[0].id, contextID: before.id, revision: revision))
        XCTAssertEqual(controller.presentation, .file)
        XCTAssertNotEqual(controller.captionRevision, captionRevision)
        XCTAssertFalse(controller.removeItem(id: fixture.items[1].id, contextID: before.id, revision: revision))
        XCTAssertFalse(controller.canSend)
        await drain()
        XCTAssertTrue(controller.canSend); XCTAssertFalse(controller.canRetryRecovery)
        let saved = try XCTUnwrap(repository.value)
        XCTAssertEqual(saved.items, Array(before.items.dropFirst())); XCTAssertEqual(saved.presentation, .file)
        XCTAssertEqual(saved.captionInput, before.captionInput)
        XCTAssertTrue(saved.captionAboveMedia); XCTAssertTrue(saved.mediaSpoiler); XCTAssertFalse(saved.isGrouped)
        let firstWrite = try XCTUnwrap(repository.writes.dropFirst(writes).first)
        XCTAssertEqual(firstWrite.items, saved.items); XCTAssertEqual(firstWrite.presentation, .file)
        XCTAssertTrue(firstWrite.isValid, "No intermediate pointer may contain documents in Media mode")
    }

    func testLastVisualRemovalRetriesBeforeCommitWithoutRecapture() async throws {
        try await assertRemovalRetry()
    }

    func testLastVisualRemovalLostAcknowledgementReusesCommittedOrderAndMode() async throws {
        try await assertRemovalRetry(commitBeforeFailure: true)
    }

    func testLastVisualRemovalRetryCannotRewriteCancellation() async throws {
        try await assertRemovalRetry(replacement: .cancelled)
    }

    func testLastVisualRemovalRetryCannotRewriteANewerPreparation() async throws {
        try await assertRemovalRetry(replacement: .newer)
    }

    func testLastVisualRemovalRejectsStaleDurableMode() async throws {
        let fixture = try await fixture(mixed: true), controller = TelegramUploadController()
        let repository = Repository(fixture.draft), store = session(repository)
        controller.bind(provider: Provider(), recoveryStore: store, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        defer { controller.clear() }
        let before = fixture.draft
        let replacement = try TelegramPendingUploadDraft(id: before.id, accountID: before.accountID, chatID: before.chatID,
            title: before.title, captionInput: before.captionInput, originalDraft: before.originalDraft,
            replyTarget: before.replyTarget, items: before.items, isGrouped: before.isGrouped, presentation: .file)
        repository.value = replacement
        XCTAssertTrue(controller.removeItem(id: fixture.items[0].id, contextID: before.id, revision: controller.itemsRevision))
        await drain()
        XCTAssertEqual(repository.value, replacement, "A list action from the old mode must not alter the newer durable choice")
        XCTAssertTrue(controller.canRetryRecovery); XCTAssertFalse(controller.canSend)
    }

    func testLegacyItemRemovalNormalizesModeWithoutUpgradingCodec() async throws {
        let fixture = try await fixture(mixed: true, extraDocument: true)
        defer { for item in fixture.items { try? item.discard() } }
        for keepsOriginal in [false, true] {
            let items = fixture.draft.items.map {
                TelegramPendingUploadItem(id: $0.id, file: $0.file, video: $0.video, videoCover: $0.videoCover,
                    originalFile: keepsOriginal ? $0.originalFile : nil)
            }
            let legacy = try TelegramPendingUploadDraft(id: fixture.draft.id, accountID: 1, chatID: 42, title: "Synthetic legacy",
                captionInput: fixture.draft.captionInput,
                originalDraft: nil, replyTarget: nil, items: items, isGrouped: false)
            XCTAssertEqual(legacy.schemaVersion, keepsOriginal ? 7 : 6)
            guard legacy.isValid else { return XCTFail("Legacy compatibility must start from an admissible schema6/7 pointer") }
            let repository = Repository(legacy), store = session(repository)
            let remaining = Array(items.dropFirst().reversed())
            // Old callers retain their original signature and legacy encoding.
            try await store.updateItems(preparationID: legacy.id, previousIDs: items.map(\.id), previousGrouping: false,
                orderedIDs: remaining.map(\.id), isGrouped: false, target: target)
            let saved = try XCTUnwrap(repository.value)
            XCTAssertEqual(saved.schemaVersion, 6); XCTAssertEqual(saved.presentation, .file)
            XCTAssertEqual(saved.items, remaining); XCTAssertEqual(saved.captionInput, legacy.captionInput)
            XCTAssertFalse(saved.captionAboveMedia); XCTAssertFalse(saved.mediaSpoiler)
            try await store.updateItems(preparationID: legacy.id, previousIDs: items.map(\.id), previousGrouping: false,
                orderedIDs: remaining.map(\.id), isGrouped: false, target: target)
            XCTAssertEqual(repository.value, saved, "A legacy lost ACK must reuse the exact committed pointer")
        }
    }

    func testDetachedLastVisualRemovalFailureRetriesOriginalOrderedPointer() async throws {
        try await assertDetachedItemsRetry()
    }

    func testDetachedLastVisualRemovalLostAcknowledgementKeepsExactCommittedOrder() async throws {
        try await assertDetachedItemsRetry(commitBeforeFailure: true)
    }

    func testDetachedLastVisualRemovalCannotRewriteCancellation() async throws {
        try await assertDetachedItemsRetry(replacement: .cancelled)
    }

    func testDetachedLastVisualRemovalCannotRewriteANewerPreparation() async throws {
        try await assertDetachedItemsRetry(replacement: .newer)
    }

    func testDetachedLastVisualRemovalSuccessKeepsLatestRichCaption() async throws {
        try await assertDetachedItemsRetry(commitBeforeFailure: true, acknowledged: true)
    }

    func testDetachedGroupingFailureRetriesOnlyOriginalStore() async throws {
        let fixture = try await fixture(), controller = TelegramUploadController()
        let repository = Repository(fixture.draft), original = session(repository), nextRepository = Repository(nil)
        controller.bind(provider: Provider(), recoveryStore: original, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        repository.holdNextWrite = true
        XCTAssertTrue(controller.updateGrouping(false, contextID: fixture.draft.id, revision: controller.itemsRevision))
        await drain(); XCTAssertNotNil(repository.held)
        controller.bind(provider: Provider(), recoveryStore: session(nextRepository), requiresRecovery: true)
        repository.release(commit: false); await drain()
        XCTAssertTrue(controller.canRetryDetachedRecovery)
        controller.retryDetachedRecovery(); await drain()
        XCTAssertFalse(try XCTUnwrap(repository.value).isGrouped)
        XCTAssertEqual(repository.value?.items, fixture.draft.items); XCTAssertEqual(repository.value?.presentation, .media)
        XCTAssertFalse(controller.canRetryDetachedRecovery); XCTAssertNil(nextRepository.value)
    }

    func testCancelledHeldItemsReleaseOriginalStoreAfterRebind() async throws {
        let fixture = try await fixture(mixed: true), controller = TelegramUploadController()
        var repository: Repository? = Repository(fixture.draft)
        weak let observed = repository
        var original: TelegramPendingUploadSession? = session(try XCTUnwrap(repository))
        controller.bind(provider: Provider(), recoveryStore: original, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        repository?.holdNextWrite = true
        XCTAssertTrue(controller.removeItem(id: fixture.items[0].id, contextID: fixture.draft.id, revision: controller.itemsRevision))
        await drain(); XCTAssertNotNil(repository?.held)
        controller.cancelPreparation()
        controller.bind(provider: Provider(), recoveryStore: session(Repository(nil)), requiresRecovery: true)
        repository?.release(commit: false); await drain()
        XCTAssertEqual(repository?.value?.disposition, .cancelled)
        original = nil; repository = nil; await drain()
        XCTAssertNil(observed, "Cancelling a held item operation must release its original store after completion")
        XCTAssertFalse(controller.canRetryDetachedRecovery); XCTAssertNil(controller.detachedRecoveryStatus)
    }

    private func assertDetachedItemsRetry(commitBeforeFailure: Bool = false, acknowledged: Bool = false,
                                          replacement: Replacement? = nil) async throws {
        let fixture = try await fixture(mixed: true, extraDocument: true), controller = TelegramUploadController(), provider = Provider()
        let repository = Repository(fixture.draft), original = session(repository), nextRepository = Repository(nil)
        controller.bind(provider: provider, recoveryStore: original, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        XCTAssertTrue(controller.moveItem(id: fixture.items[2].id, to: 1, contextID: fixture.draft.id, revision: controller.itemsRevision))
        await drain()
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        await drain()
        let before = try XCTUnwrap(repository.value)
        repository.holdNextWrite = true
        XCTAssertTrue(controller.removeItem(id: fixture.items[0].id, contextID: before.id, revision: controller.itemsRevision))
        await drain(); XCTAssertNotNil(repository.held)
        let rich = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "detached 😀", entities: [.init(offset: 9, length: 2, kind: .bold)]),
            selection: .init(location: 9, length: 2))
        XCTAssertTrue(controller.updateCaptionInput(rich, contextID: controller.captionContextID))
        XCTAssertFalse(controller.canSend); controller.send(); XCTAssertTrue(provider.submissions.isEmpty)
        controller.bind(provider: Provider(), recoveryStore: session(nextRepository), requiresRecovery: true)
        let restoreItems = try await stages(fixture.sources)
        let orderedRestore = [restoreItems[0], restoreItems[2], restoreItems[1]]
        defer { for item in restoreItems { try? item.discard() } }
        let controlItems = try await stages(fixture.sources), control = TelegramUploadController()
        control.bind(provider: Provider(), recoveryStore: session(Repository(before)), requiresRecovery: true)
        XCTAssertTrue(control.restore(draft: before, items: [controlItems[0], controlItems[2], controlItems[1]], target: target,
            restorationEpoch: control.recoveryRestoreEpoch), "The old pointer and equivalent owned stages must be independently admissible")
        control.clear()
        controller.bind(provider: provider, recoveryStore: original, requiresRecovery: true)
        XCTAssertFalse(controller.restore(draft: before, items: orderedRestore, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch), "A pending item CAS cannot restore its old pointer")
        repository.release(commit: commitBeforeFailure, acknowledged: acknowledged); await drain()
        if !acknowledged {
            XCTAssertTrue(controller.canRetryDetachedRecovery); XCTAssertNotNil(controller.detachedRecoveryStatus)
            XCTAssertFalse(controller.restore(draft: before, items: orderedRestore, target: target,
                restorationEpoch: controller.recoveryRestoreEpoch), "Failure must keep the unconfirmed order/mode blocked")
            var retained: TelegramPendingUploadDraft?
            if replacement == .cancelled {
                retained = before.updating(captionInput: rich, captionAboveMedia: true, mediaSpoiler: true, disposition: .cancelled)
            } else if replacement == .newer {
                let newer = try await self.fixture()
                retained = newer.draft
                for item in newer.items { try? item.discard() }
            }
            if let retained { repository.value = retained }
            controller.retryDetachedRecovery(); await drain()
            if let retained {
                XCTAssertEqual(repository.value, retained)
                XCTAssertTrue(controller.canRetryDetachedRecovery); XCTAssertFalse(controller.canSend)
            }
        }
        if replacement == nil {
            let saved = try XCTUnwrap(repository.value)
            XCTAssertEqual(saved.items, Array(before.items.dropFirst())); XCTAssertEqual(saved.presentation, .file)
            XCTAssertFalse(saved.isGrouped); XCTAssertEqual(saved.captionInput, rich)
            XCTAssertTrue(saved.captionAboveMedia); XCTAssertTrue(saved.mediaSpoiler)
            XCTAssertFalse(controller.canRetryDetachedRecovery); XCTAssertNil(controller.detachedRecoveryStatus)
        }
        XCTAssertNil(nextRepository.value); XCTAssertTrue(provider.submissions.isEmpty)
        XCTAssertEqual(controller.phase, .idle); XCTAssertFalse(controller.canSend)
    }

    private func assertRemovalRetry(commitBeforeFailure: Bool = false, replacement: Replacement? = nil) async throws {
        let fixture = try await fixture(mixed: true, extraDocument: true), controller = TelegramUploadController(), provider = Provider()
        let repository = Repository(fixture.draft), store = session(repository)
        controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        defer { controller.clear() }
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        await drain()
        let before = try XCTUnwrap(repository.value)
        repository.holdNextWrite = true
        XCTAssertTrue(controller.removeItem(id: fixture.items[0].id, contextID: before.id, revision: controller.itemsRevision))
        await drain()
        guard repository.held != nil else { return XCTFail("The atomic order/mode write must reach the real Session repository boundary") }
        XCTAssertFalse(controller.canSend); controller.send(); XCTAssertTrue(provider.submissions.isEmpty)
        repository.release(commit: commitBeforeFailure); await drain()
        XCTAssertTrue(controller.canRetryRecovery); XCTAssertFalse(controller.canSend)
        var retained: TelegramPendingUploadDraft?
        if replacement == .cancelled {
            retained = before.updating(captionInput: before.captionInput, captionAboveMedia: true, mediaSpoiler: true, disposition: .cancelled)
        } else if replacement == .newer {
            let newer = try await self.fixture()
            retained = newer.draft
            for item in newer.items { try? item.discard() }
        }
        if let retained { repository.value = retained }
        controller.retryRecovery(); await drain()
        if let retained {
            XCTAssertEqual(repository.value, retained)
            XCTAssertFalse(controller.canSend); XCTAssertTrue(controller.canRetryRecovery)
        } else {
            let saved = try XCTUnwrap(repository.value)
            XCTAssertEqual(saved.items, Array(before.items.dropFirst())); XCTAssertEqual(saved.presentation, .file)
            XCTAssertEqual(saved.captionInput, before.captionInput)
            XCTAssertTrue(saved.captionAboveMedia); XCTAssertTrue(saved.mediaSpoiler); XCTAssertFalse(saved.isGrouped)
            XCTAssertTrue(controller.canSend); XCTAssertFalse(controller.canRetryRecovery)
        }
        XCTAssertTrue(provider.submissions.isEmpty)
    }

    private enum Replacement { case cancelled, newer }
    private func assertDetachedRetry(commitBeforeFailure: Bool = false, replacement: Replacement? = nil) async throws {
        let fixture = try await fixture(), controller = TelegramUploadController(), provider = Provider()
        let repository = Repository(fixture.draft), original = session(repository)
        controller.bind(provider: provider, recoveryStore: original, requiresRecovery: true)
        XCTAssertTrue(controller.restore(draft: fixture.draft, items: fixture.items, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch))
        let rich = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "latest 😀", entities: [.init(offset: 7, length: 2, kind: .bold)]),
            selection: .init(location: 7, length: 2))
        XCTAssertTrue(controller.updateCaptionInput(rich, contextID: controller.captionContextID))
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        await drain()
        let before = try XCTUnwrap(repository.value)
        repository.holdNextWrite = true
        XCTAssertTrue(controller.updatePresentation(.file, contextID: before.id, revision: controller.itemsRevision))
        await drain(); XCTAssertNotNil(repository.held); XCTAssertFalse(controller.canSend)
        let nextRepository = Repository(nil), nextProvider = Provider()
        controller.bind(provider: nextProvider, recoveryStore: session(nextRepository), requiresRecovery: true)
        repository.release(commit: commitBeforeFailure); await drain()
        XCTAssertTrue(controller.canRetryDetachedRecovery, "The original failed mode must remain recoverable after rebind")
        XCTAssertNotNil(controller.detachedRecoveryStatus)
        XCTAssertFalse(controller.canSend)
        let restoreItems = try await stages(fixture.sources)
        defer { for item in restoreItems { try? item.discard() } }
        let controlItems = try await stages(fixture.sources)
        let control = TelegramUploadController()
        control.bind(provider: Provider(), recoveryStore: session(Repository(before)), requiresRecovery: true)
        XCTAssertTrue(control.restore(draft: before, items: controlItems, target: target,
            restorationEpoch: control.recoveryRestoreEpoch), "The same fresh stages must pass an independent restore")
        control.clear()
        controller.bind(provider: provider, recoveryStore: original, requiresRecovery: true)
        XCTAssertFalse(controller.restore(draft: before, items: restoreItems, target: target,
            restorationEpoch: controller.recoveryRestoreEpoch), "An unconfirmed old mode must not become sendable")
        var retained: TelegramPendingUploadDraft?
        if replacement == .cancelled {
            retained = before.updating(captionInput: rich, captionAboveMedia: true, mediaSpoiler: true, disposition: .cancelled)
        } else if replacement == .newer {
            let newer = try await self.fixture()
            retained = newer.draft
            for item in newer.items { try? item.discard() }
        }
        if let retained { repository.value = retained }
        controller.retryDetachedRecovery(); await drain()
        if let retained {
            XCTAssertEqual(repository.value, retained, "Retry must preserve cancellation or a newer durable preparation")
            XCTAssertTrue(controller.canRetryDetachedRecovery)
        } else {
            let saved = try XCTUnwrap(repository.value)
            XCTAssertEqual(saved.id, before.id); XCTAssertEqual(saved.items, before.items)
            XCTAssertEqual(saved.presentation, .file); XCTAssertTrue(saved.isGrouped)
            XCTAssertEqual(saved.captionInput, rich); XCTAssertTrue(saved.captionAboveMedia); XCTAssertTrue(saved.mediaSpoiler)
            XCTAssertFalse(controller.canRetryDetachedRecovery); XCTAssertNil(controller.detachedRecoveryStatus)
        }
        XCTAssertNil(nextRepository.value)
        XCTAssertTrue(provider.submissions.isEmpty); XCTAssertTrue(nextProvider.submissions.isEmpty)
        XCTAssertEqual(controller.phase, .idle); XCTAssertFalse(controller.canSend)
    }

    private let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
    private func drain() async { for _ in 0..<200 { await Task.yield() } }
    private func session(_ repository: Repository) -> TelegramPendingUploadSession {
        TelegramPendingUploadSession(repository: repository, files: { throw TelegramPendingUploadPersistenceError.unavailable })
    }
    private func fixture(mixed: Bool = false, extraDocument: Bool = false) async throws -> (draft: TelegramPendingUploadDraft, items: [TelegramUploadBatchItem], sources: [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        var sources = [root.appendingPathComponent("first.jpg"), root.appendingPathComponent(mixed ? "second.txt" : "second.jpg")]
        try writeUploadVideoCoverFixture(sources[0])
        if mixed { try Data("owned document".utf8).write(to: sources[1]) }
        else { try writeUploadVideoCoverFixture(sources[1]) }
        if extraDocument {
            let document = root.appendingPathComponent("third.txt")
            try Data("third owned document".utf8).write(to: document); sources.append(document)
        }
        let items = try await stages(sources), id = UUID()
        let identity = TelegramPendingUploadDraft.archiveIdentity(accountID: 1, chatID: 42, preparationID: id)
        func record(_ file: TelegramUploadFile, attachmentID: String) throws -> ArchiveFileRecord {
            let object = UUID()
            let receipt = try ArchiveFileCapture(file: file.url, byteCount: file.size)
                .seal(to: root.appendingPathComponent(object.uuidString), key: Data(repeating: 7, count: 32), objectID: object)
            return ArchiveFileRecord(id: object, identity: identity,
                attachment: .init(id: attachmentID, kind: file.mode.rawValue, name: file.name, size: file.size),
                objectKey: "local-preparations/synthetic/files/" + object.uuidString.lowercased(), storageID: String(repeating: "a", count: 64),
                receipt: receipt, state: .local, purpose: .outgoing(defaultEnabled: false))
        }
        let saved = try items.map { item in
            TelegramPendingUploadItem(id: item.id, file: try record(item.file, attachmentID: TelegramPendingUploadItem.attachmentID(item.id)),
                originalFile: try item.originalFile.map { try record($0, attachmentID: TelegramPendingUploadItem.originalAttachmentID(item.id)) })
        }
        let caption = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "original 😀", entities: [.init(offset: 9, length: 2, kind: .italic)]))
        let draft = try TelegramPendingUploadDraft(id: id, accountID: 1, chatID: 42, title: "Synthetic", captionInput: caption,
            originalDraft: nil, replyTarget: nil, items: saved, isGrouped: !mixed, presentation: .media)
        XCTAssertTrue(draft.isValid)
        return (draft, items, sources)
    }
    private func stages(_ sources: [URL]) async throws -> [TelegramUploadBatchItem] {
        var items: [TelegramUploadBatchItem] = []
        for (index, source) in sources.enumerated() {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 11))!
            let original = try await TelegramUploadFileIO.stage(source, mode: .file)
            if source.pathExtension == "jpg" {
                let jpeg = try await TelegramUploadFileIO.stage(original.url, mode: .photo)
                let photo = TelegramUploadFile(id: jpeg.id, name: source.lastPathComponent, size: jpeg.size, mode: .photo,
                    pixelWidth: jpeg.pixelWidth, pixelHeight: jpeg.pixelHeight, url: jpeg.url, directory: jpeg.directory)
                items.append(.init(id: id, file: photo, originalFile: original))
            } else { items.append(.init(id: id, file: original)) }
        }
        return items
    }
    @MainActor private final class Repository: TelegramPendingUploadRepository {
        let accountID: Int64 = 1
        var value: TelegramPendingUploadDraft?
        var writes: [TelegramPendingUploadDraft] = []
        var holdNextWrite = false
        var held: (draft: TelegramPendingUploadDraft, revision: UUID?, completion: @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void)?
        init(_ value: TelegramPendingUploadDraft?) { self.value = value }
        func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
            completion(.success(value)); return EmptyDisposable
        }
        func save(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID?, completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
            guard value?.revision == expectedRevision else { completion(.failure(.conflict)); return }
            writes.append(draft)
            if holdNextWrite { holdNextWrite = false; held = (draft, expectedRevision, completion) }
            else { value = draft; completion(.success(())) }
        }
        func release(commit: Bool, acknowledged: Bool = false) {
            guard let held else { return }
            self.held = nil
            if commit, value?.revision == held.revision { value = held.draft }
            held.completion(acknowledged ? .success(()) : .failure(.unavailable))
        }
    }
    @MainActor private final class Provider: TelegramUploadBatchProvider {
        let accountID: Int64 = 1
        var submissions: [TelegramPendingUploadDraft] = []
        func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                    receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
            submissions.append(draft); return Lease()
        }
        func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
                    captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
            XCTFail("Batch recovery must submit the complete set"); return Lease()
        }
    }
    @MainActor private final class Lease: TelegramUploadLease { func stop() {} }
}

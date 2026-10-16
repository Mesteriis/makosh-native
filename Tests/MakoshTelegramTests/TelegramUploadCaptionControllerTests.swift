import XCTest
import Foundation
@testable import MakoshTelegram

@MainActor final class TelegramUploadCaptionControllerTests: TelegramSourceFactsIntegrationTestCase {
    // Catches the UI retaining the old 1024 gate while persistence and native admission support a premium policy.
    func testCurrentPolicyPreparesRestoresAndEditsTheWholeSetUnderBothStoragePolicies() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let first = fixture.root.appendingPathComponent("a.txt"), second = fixture.root.appendingPathComponent("b.txt")
            try Data("a".utf8).write(to: first); try Data("b".utf8).write(to: second)
            let input = try TelegramComposerInput(formattedText: .init(text: " **" + String(repeating: "я", count: 1500) + "** #media "))
            let store = fixture.session(box), controller = TelegramUploadController()
            controller.bind(provider: CaptionControllerProvider(), recoveryStore: store, requiresRecovery: true)
            defer { controller.clear() }
            controller.prepare(sources: [first, second].map { .init(source: $0, mode: .file) }, isGrouped: false,
                target: fixture.target, captionInput: input, captionPolicy: try .init(maximumUTF16Count: 2048))
            try await waitForReady(controller)
            XCTAssertTrue(controller.canSend); XCTAssertEqual(controller.captionMaximumUTF16Count, 2048)
            XCTAssertTrue(controller.canUseArchivePresentation)
            let frozen = try await sourceFactsLoad(store)
            XCTAssertEqual(frozen.schemaVersion, 19); XCTAssertEqual(frozen.captionPolicy?.maximumUTF16Count, 2048)
            XCTAssertEqual(frozen.captionInput, input)
            guard frozen.schemaVersion == 19 else { continue }
            let active = TelegramUploadController()
            active.bind(provider: CaptionControllerProvider(), recoveryStore: store, requiresRecovery: true)
            defer { active.clear() }
            let restored = try await store.restoreBundle(draft: frozen)
            let restoredUpload1 = await active.restore(draft: frozen, bundle: restored, target: fixture.target,
                restorationEpoch: active.recoveryRestoreEpoch)
            XCTAssertTrue(restoredUpload1)
            XCTAssertTrue(active.canSend); XCTAssertEqual(active.captionMaximumUTF16Count, 2048)
            let id = try XCTUnwrap(active.preparationContextID), oldIDs = active.items.map(\.id)
            XCTAssertTrue(active.moveItem(id: oldIDs[1], to: 0, contextID: id, revision: active.itemsRevision))
            try await waitForReady(active)
            let reordered = try await sourceFactsLoad(store)
            XCTAssertEqual(reordered.captionPolicy?.items.map(\.itemID), Array(oldIDs.reversed()))
            XCTAssertTrue(active.updatePresentation(.archive, contextID: id, revision: active.itemsRevision))
            try await waitForReady(active)
            XCTAssertEqual(active.presentation, .archive); XCTAssertTrue(active.canSend)
            let archived = try await sourceFactsLoad(store)
            XCTAssertEqual(archived.captionPolicy?.maximumUTF16Count, 2048)
            XCTAssertTrue(active.updatePresentation(.file, contextID: id, revision: active.itemsRevision))
            try await waitForReady(active)
            XCTAssertTrue(active.removeItem(id: oldIDs[0], contextID: id, revision: active.itemsRevision))
            try await waitForReady(active)
            XCTAssertTrue(active.usesCaptionPlaceholder); XCTAssertTrue(active.canSend)
            let removed = try await sourceFactsLoad(store)
            XCTAssertEqual(removed.captionPolicy?.items.map(\.itemID), [oldIDs[1]])
            let over = try TelegramComposerInput(formattedText: .init(text: String(repeating: "x", count: 2049)))
            XCTAssertTrue(active.updateCaptionInput(over, contextID: active.captionContextID))
            XCTAssertFalse(active.canSend)
        }
    }

    // Catches silently upgrading the validation/projection of previously prepared attachments.
    func testDefaultControllerPreparationRetainsFrozenLegacyReferenceLimit() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let source = fixture.root.appendingPathComponent("legacy.txt"); try Data("legacy".utf8).write(to: source)
        let store = fixture.session(box), controller = TelegramUploadController()
        controller.bind(provider: CaptionControllerProvider(), recoveryStore: store, requiresRecovery: true)
        defer { controller.clear() }
        let input = try TelegramComposerInput(formattedText: .init(text: String(repeating: "x", count: 1025)))
        controller.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false, target: fixture.target, captionInput: input)
        try await waitForReady(controller)
        let frozen = try await sourceFactsLoad(store)
        XCTAssertEqual(frozen.schemaVersion, 17); XCTAssertNil(frozen.captionPolicy)
        XCTAssertEqual(controller.captionMaximumUTF16Count, 1024); XCTAssertFalse(controller.canSend)
    }

    private func waitForReady(_ controller: TelegramUploadController) async throws {
        for _ in 0..<1000 where controller.phase == .preparing || controller.isRecoveryBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.phase, .ready); XCTAssertFalse(controller.isRecoveryBusy)
        XCTAssertNil(controller.recoveryStatus)
    }
}

@MainActor private final class CaptionControllerProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Preparation and restoration never send"); return CaptionControllerLease()
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
                captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Preparation and restoration never send"); return CaptionControllerLease()
    }
}
@MainActor private final class CaptionControllerLease: TelegramUploadLease { func stop() {} }

import XCTest
import Foundation
import AppKit
import SwiftUI
import TelegramCore
import Postbox
import SwiftSignalKit
@testable import MakoshApp
@testable import MakoshTelegram

@MainActor final class TelegramCustomEmojiCaptionTests: TelegramSourceFactsIntegrationTestCase {
    // Catches caption picks borrowing the ordinary composer's identity, bypassing
    // the current caption selection/revision or replaying after a new preview.
    func testCaptionPickRequiresItsOwnExactRevisionSelectionTargetAndCurrentCatalog() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let source = fixture.root.appendingPathComponent("caption.txt")
        try Data("caption payload".utf8).write(to: source)
        let provider = CaptionEmojiCatalogProvider(accountID: 1), catalog = TelegramCustomEmojiCatalogController()
        let free = try captionEmoji(100), paid = try captionEmoji(101, premium: true)
        catalog.bind(provider: provider); provider.publish(.standard, items: [free, paid])
        let upload = TelegramUploadController(), store = fixture.session(box)
        defer { upload.clear() }
        upload.bind(provider: CaptionEmojiUploadProvider(), recoveryStore: store, requiresRecovery: true)
        let original = try TelegramComposerInput(formattedText: .init(text: "abc"), selection: .init(location: 1, length: 1))
        upload.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false, target: fixture.target,
            captionInput: original, captionPolicy: try .init(maximumUTF16Count: 1024))
        try await waitUntil { upload.phase == .ready && !upload.isRecoveryBusy }
        let preparationID = try XCTUnwrap(upload.preparationContextID)
        let context = upload.captionContextID, revision = upload.captionRevision, catalogContext = catalog.contextID
        XCTAssertTrue(upload.canInsertCaptionCustomEmoji)
        XCTAssertFalse(upload.requestCaptionCustomEmojiInsertion(descriptor: paid, catalog: catalog,
            catalogContextID: catalogContext, expectedInput: original, contextID: context, revision: revision, preparationID: preparationID))
        XCTAssertFalse(upload.requestCaptionCustomEmojiInsertion(descriptor: free, catalog: catalog,
            catalogContextID: catalogContext, expectedInput: original, contextID: context, revision: UUID(), preparationID: preparationID))
        XCTAssertFalse(upload.requestCaptionCustomEmojiInsertion(descriptor: free, catalog: catalog,
            catalogContextID: catalogContext, expectedInput: original, contextID: context, revision: revision, preparationID: UUID()))
        let otherSelection = try TelegramComposerInput(formattedText: original.formattedText, selection: .init(location: 2, length: 0))
        XCTAssertFalse(upload.requestCaptionCustomEmojiInsertion(descriptor: free, catalog: catalog,
            catalogContextID: catalogContext, expectedInput: otherSelection, contextID: context, revision: revision, preparationID: preparationID))
        guard upload.requestCaptionCustomEmojiInsertion(descriptor: free, catalog: catalog,
            catalogContextID: catalogContext, expectedInput: original, contextID: context, revision: revision, preparationID: preparationID) else {
            return XCTFail("Current caption/catalog admission must create its own native edit request")
        }
        let request = try XCTUnwrap(upload.captionCustomEmojiInsertion)
        XCTAssertEqual(request.contextID, context)
        XCTAssertFalse(upload.consumeCaptionCustomEmojiInsertion(id: request.id, expectedInput: otherSelection))
        XCTAssertNil(upload.captionCustomEmojiInsertion)
        XCTAssertFalse(upload.consumeCaptionCustomEmojiInsertion(id: request.id, expectedInput: original))

        provider.publish(.premium, items: [free, paid])
        XCTAssertTrue(upload.requestCaptionCustomEmojiInsertion(descriptor: paid, catalog: catalog,
            catalogContextID: catalog.contextID, expectedInput: original, contextID: context, revision: revision, preparationID: preparationID))
        let paidRequest = try XCTUnwrap(upload.captionCustomEmojiInsertion)
        provider.publish(.standard, items: [free, paid])
        XCTAssertFalse(upload.consumeCaptionCustomEmojiInsertion(id: paidRequest.id, expectedInput: original))
        XCTAssertEqual(upload.captionInput, original)

        XCTAssertTrue(upload.requestCaptionCustomEmojiInsertion(descriptor: free, catalog: catalog,
            catalogContextID: catalog.contextID, expectedInput: original, contextID: context, revision: revision, preparationID: preparationID))
        let stale = try XCTUnwrap(upload.captionCustomEmojiInsertion)
        XCTAssertTrue(upload.updateCaptionInput(otherSelection, contextID: context))
        XCTAssertTrue(upload.updateCaptionInput(original, contextID: context))
        XCTAssertFalse(upload.consumeCaptionCustomEmojiInsertion(id: stale.id, expectedInput: original))
        XCTAssertFalse(upload.requestCaptionCustomEmojiInsertion(descriptor: free, catalog: catalog,
            catalogContextID: catalog.contextID, expectedInput: original, contextID: context, revision: revision, preparationID: preparationID))

        let currentRevision = upload.captionRevision
        XCTAssertTrue(upload.requestCaptionCustomEmojiInsertion(descriptor: free, catalog: catalog,
            catalogContextID: catalog.contextID, expectedInput: original, contextID: context, revision: currentRevision, preparationID: preparationID))
        let oldAccount = try XCTUnwrap(upload.captionCustomEmojiInsertion)
        catalog.bind(provider: CaptionEmojiCatalogProvider(accountID: 2))
        XCTAssertFalse(upload.consumeCaptionCustomEmojiInsertion(id: oldAccount.id, expectedInput: original))
        catalog.bind(provider: provider); provider.publish(.standard, items: [free])
        XCTAssertTrue(upload.requestCaptionCustomEmojiInsertion(descriptor: free, catalog: catalog,
            catalogContextID: catalog.contextID, expectedInput: original, contextID: context, revision: currentRevision, preparationID: preparationID))
        let detached = try XCTUnwrap(upload.captionCustomEmojiInsertion)
        upload.bind(provider: CaptionEmojiUploadProvider(), recoveryStore: store, requiresRecovery: true)
        XCTAssertNil(upload.captionCustomEmojiInsertion)
        XCTAssertFalse(upload.consumeCaptionCustomEmojiInsertion(id: detached.id, expectedInput: original))
    }

    // Catches a caption picker that edits a plain string or a separate composer,
    // losing typed entities/selection, native Undo or the durable wire22 marker.
    func testAdmittedCaptionInsertionUsesNativeUndoRedoAndPersistsExtendedCaption() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let source = fixture.root.appendingPathComponent("native-caption.txt")
        try Data("native caption payload".utf8).write(to: source)
        let upload = TelegramUploadController(), store = fixture.session(box)
        defer { upload.clear() }
        upload.bind(provider: CaptionEmojiUploadProvider(), recoveryStore: store, requiresRecovery: true)
        let original = try TelegramComposerInput(formattedText: .init(text: "axb", entities: [.init(offset: 0, length: 3, kind: .bold)]),
            selection: .init(location: 1, length: 1))
        upload.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false, target: fixture.target,
            captionInput: original, captionPolicy: try .init(maximumUTF16Count: 1024))
        try await waitUntil { upload.phase == .ready && !upload.isRecoveryBusy }
        let descriptor = try captionEmoji(100), catalog = TelegramCustomEmojiCatalogController()
        let provider = CaptionEmojiCatalogProvider(accountID: 1)
        catalog.bind(provider: provider); provider.publish(.standard, items: [descriptor])
        let preparationID = try XCTUnwrap(upload.preparationContextID), context = upload.captionContextID
        guard upload.requestCaptionCustomEmojiInsertion(descriptor: descriptor, catalog: catalog,
            catalogContextID: catalog.contextID, expectedInput: original, contextID: context,
            revision: upload.captionRevision, preparationID: preparationID) else {
            return XCTFail("The caption picker must admit the exact current selection")
        }
        let request = try XCTUnwrap(upload.captionCustomEmojiInsertion), state = CaptionEmojiInputState()
        let coordinator = NativeTelegramText.Coordinator(value: Binding(get: { upload.captionInput.formattedText }, set: { _ in }),
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            height: Binding(get: { state.height }, set: { state.height = $0 }), selection: original.selection,
            inputChanged: { _ = upload.updateCaptionInput($0, contextID: context) })
        let text = CaptionEmojiUndoText(frame: .init(x: 0, y: 0, width: 200, height: 80))
        text.allowsUndo = true; text.isEditable = true; text.delegate = coordinator
        text.nativeUndo.groupsByEvent = false
        coordinator.install(original.formattedText, in: text)
        defer { coordinator.detach() }
        text.nativeUndo.beginUndoGrouping()
        coordinator.insertCustomEmoji(request, contextID: context, in: text) { id, input in
            upload.consumeCaptionCustomEmojiInsertion(id: id, expectedInput: input)
        }
        text.nativeUndo.endUndoGrouping()
        let expected = try TelegramComposerInput(formattedText: .init(text: "a🦊b", entities: [
            .init(offset: 0, length: 4, kind: .bold),
            .init(offset: 1, length: 2, kind: .customEmoji(stickerPack: .id(id: 77, accessHash: 79), fileID: 100))]),
            selection: .init(location: 3, length: 0))
        XCTAssertEqual(upload.captionInput, expected); XCTAssertEqual(text.string, "a🦊b")
        XCTAssertNil(upload.captionCustomEmojiInsertion); XCTAssertNil(state.error)
        let inserted = try await saved(expected, store: store)
        XCTAssertEqual(inserted.schemaVersion, 22); XCTAssertEqual(inserted.captionInput, expected)
        text.nativeUndo.undo()
        XCTAssertEqual(upload.captionInput, original)
        let undone = try await saved(original, store: store)
        XCTAssertEqual(undone.schemaVersion, 22); XCTAssertEqual(undone.captionInput, original)
        text.nativeUndo.redo()
        XCTAssertEqual(upload.captionInput, expected)
        let redone = try await saved(expected, store: store)
        XCTAssertEqual(redone.captionInput, expected); XCTAssertEqual(redone.id, preparationID)
        XCTAssertFalse(upload.consumeCaptionCustomEmojiInsertion(id: request.id, expectedInput: original))
    }

    // Catches extending a frozen legacy caption policy merely by opening the picker.
    func testReferencePreparationDoesNotAdmitCustomEmojiPicker() async throws {
        let fixture = try await sourceFactsArchive(), box = try await sourceFactsOpen(fixture.postboxPath)
        let source = fixture.root.appendingPathComponent("reference-caption.txt")
        try Data("reference payload".utf8).write(to: source)
        let upload = TelegramUploadController(), store = fixture.session(box)
        defer { upload.clear() }
        upload.bind(provider: CaptionEmojiUploadProvider(), recoveryStore: store, requiresRecovery: true)
        upload.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false,
            target: fixture.target, captionInput: .empty)
        try await waitUntil { upload.phase == .ready && !upload.isRecoveryBusy }
        let descriptor = try captionEmoji(100), catalog = TelegramCustomEmojiCatalogController()
        let provider = CaptionEmojiCatalogProvider(accountID: 1)
        catalog.bind(provider: provider); provider.publish(.premium, items: [descriptor])
        let frozen = try await sourceFactsLoad(store), preparationID = try XCTUnwrap(upload.preparationContextID)
        XCTAssertEqual(frozen.schemaVersion, 17)
        XCTAssertFalse(upload.canInsertCaptionCustomEmoji)
        XCTAssertFalse(upload.requestCaptionCustomEmojiInsertion(descriptor: descriptor, catalog: catalog,
            catalogContextID: catalog.contextID, expectedInput: .empty, contextID: upload.captionContextID,
            revision: upload.captionRevision, preparationID: preparationID))
        XCTAssertNil(upload.captionCustomEmojiInsertion)
        let unchanged = try await sourceFactsLoad(store)
        XCTAssertEqual(unchanged, frozen)
    }

    private func saved(_ input: TelegramComposerInput, store: TelegramPendingUploadSession) async throws -> TelegramPendingUploadDraft {
        for _ in 0..<1000 {
            let value = try await sourceFactsLoad(store)
            if value.captionInput == input { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native caption edit did not reach the durable preparation")
        throw CaptionEmojiFailure.timeout
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Caption preparation did not become ready")
        throw CaptionEmojiFailure.timeout
    }
}
private enum CaptionEmojiFailure: Error { case timeout }
@MainActor private final class CaptionEmojiInputState { var error: String?; var height: CGFloat = 52 }
@MainActor private final class CaptionEmojiUndoText: NSTextView {
    let nativeUndo = UndoManager()
    override var undoManager: UndoManager? { nativeUndo }
}
@MainActor private final class CaptionEmojiUploadProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
        captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Caption editing never sends"); return CaptionEmojiUploadLease()
    }
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
        receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Caption editing never sends"); return CaptionEmojiUploadLease()
    }
}
@MainActor private final class CaptionEmojiUploadLease: TelegramUploadLease { func stop() {} }
@MainActor private final class CaptionEmojiCatalogProvider: TelegramCustomEmojiCatalogProvider {
    let accountID: Int64
    let values = ValuePipe<TelegramCustomEmojiCatalogSnapshot>()
    init(accountID: Int64) { self.accountID = accountID }
    func publish(_ tier: TelegramCustomEmojiEntitlement, items: [TelegramCustomEmojiDescriptor]) {
        values.putNext(.init(accountID: accountID, entitlement: tier, recent: items, installed: [], featured: []))
    }
    func catalog() -> Signal<TelegramCustomEmojiCatalogSnapshot, NoError> { values.signal() }
    func search(query: String) -> Signal<TelegramCustomEmojiSearchResult, NoError> { .single(.init(items: [], isFinal: true)) }
    func loadPack(reference: TelegramStickerPackReference) -> Signal<TelegramCustomEmojiPackResult, NoError> { .single(.unavailable) }
    func setInstalled(pack: TelegramCustomEmojiPack, installed: Bool) -> Signal<Bool, NoError> { .single(false) }
}
private nonisolated func captionEmoji(_ id: Int64, premium: Bool = false) throws -> TelegramCustomEmojiDescriptor {
    try .init(file: TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil,
        resource: CloudDocumentMediaResource(datacenterId: 2, fileId: id, accessHash: 17, size: 100,
            fileReference: Data([1]), fileName: "synthetic.webp"), previewRepresentations: [], videoThumbnails: [],
        immediateThumbnailData: nil, mimeType: "image/webp", size: 100,
        attributes: [.CustomEmoji(isPremium: premium, isSingleColor: false, alt: "🦊", packReference: .id(id: 77, accessHash: 79))],
        alternativeRepresentations: []))
}

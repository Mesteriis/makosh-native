import XCTest
import AppKit
import SwiftUI
import TelegramCore
import Postbox
import SwiftSignalKit
@testable import MakoshApp
@testable import MakoshTelegram

@MainActor final class TelegramCustomEmojiUIIntegrationTests: XCTestCase {
    private final class Lease: TelegramMediaLease {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private final class Provider: TelegramCustomEmojiResourceProvider {
        let accountID: Int64 = 1
        var requests: [TelegramCustomEmojiDescriptor] = []
        var leases: [Lease] = []
        func start(descriptor: TelegramCustomEmojiDescriptor,
            receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            requests.append(descriptor); let lease = Lease(); leases.append(lease); return lease
        }
    }
    private final class InputState {
        var input: TelegramComposerInput
        var error: String?
        var height: CGFloat = 52
        init(_ input: TelegramComposerInput) { self.input = input }
    }
    private final class UndoText: NSTextView {
        let nativeUndo = UndoManager()
        override var undoManager: UndoManager? { nativeUndo }
    }
    private func reading(_ value: TelegramFormattedText, provider: Provider,
        context: TelegramCustomEmojiPlaybackContext, descriptor: TelegramCustomEmojiDescriptor,
        revealed: Bool = false) -> TelegramMessageReadingText {
        let text = TelegramMessageReadingText(frame: .init(x: 0, y: 0, width: 200, height: 80))
        text.textContainer?.containerSize = .init(width: 200, height: CGFloat.greatestFiniteMagnitude)
        text.install(presentation: TelegramMessagePresentation.attributedString(value, revealingSpoilers: revealed),
            value: value, key: .init(context: "synthetic-inline", value: value), canCopy: true,
            revealingSpoilers: revealed, customEmojiDescriptors: [descriptor.fileID: descriptor], customEmojiContext: context)
        return text
    }
    // Catches a renderer that exists only in isolation but is never installed
    // into real message reading views, or survives message-view reuse.
    func testNativeReadingUsesVisibleEmojiAndReleasesLeaseWhenReused() throws {
        let descriptor = try uiEmojiDescriptor(), provider = Provider()
        let context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider)
        let value = try emojiValue(descriptor)
        let text = reading(value, provider: provider, context: context, descriptor: descriptor)
        guard provider.requests == [descriptor] else { XCTFail("Real reading view must acquire the visible native emoji"); return }
        text.setSelectedRange(.init(location: 0, length: 2))
        text.install(presentation: TelegramMessagePresentation.attributedString(value), value: value,
            key: .init(context: "synthetic-inline", value: value), canCopy: true,
            customEmojiDescriptors: [descriptor.fileID: descriptor], customEmojiContext: context)
        XCTAssertEqual(text.selectedRange(), .init(location: 0, length: 2))
        let replacement = try TelegramFormattedText(text: "replacement")
        text.install(presentation: NSAttributedString(string: replacement.text), value: replacement,
            key: .init(context: "synthetic-reused", value: replacement), canCopy: true)
        XCTAssertTrue(provider.leases[0].cancelled)
        XCTAssertEqual(text.string, replacement.text)
    }
    // Catches revealing a custom emoji through the renderer while the native
    // reading projection still conceals its spoiler.
    func testNativeReadingConcealmentGatesFetchAndCancelsAfterReveal() throws {
        let descriptor = try uiEmojiDescriptor(), provider = Provider()
        let context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider)
        let base = try emojiValue(descriptor)
        let value = try TelegramFormattedText(text: base.text,
            entities: base.entities + [.init(offset: 0, length: 2, kind: .spoiler)])
        let text = reading(value, provider: provider, context: context, descriptor: descriptor)
        XCTAssertTrue(provider.requests.isEmpty)
        text.install(presentation: TelegramMessagePresentation.attributedString(value, revealingSpoilers: true),
            value: value, key: .init(context: "synthetic-inline", value: value), canCopy: true, revealingSpoilers: true,
            customEmojiDescriptors: [descriptor.fileID: descriptor], customEmojiContext: context)
        guard provider.requests.count == 1 else { XCTFail("Explicit spoiler reveal must reach the native overlay"); return }
        text.install(presentation: TelegramMessagePresentation.attributedString(value), value: value,
            key: .init(context: "synthetic-inline", value: value), canCopy: true,
            customEmojiDescriptors: [descriptor.fileID: descriptor], customEmojiContext: context)
        XCTAssertTrue(provider.leases[0].cancelled)
    }
    // Catches scroll clipping keeping an offscreen message's transfer and
    // decoder lease alive until the entire SwiftUI row is destroyed.
    func testNativeReadingScrollClippingReleasesThenReacquiresVisibleEmoji() throws {
        let descriptor = try uiEmojiDescriptor(), provider = Provider()
        let context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider)
        let value = try emojiValue(descriptor)
        let text = TelegramMessageReadingText(frame: .init(x: 0, y: 0, width: 200, height: 400))
        text.minSize = .init(width: 0, height: 400)
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 200, height: 60))
        scroll.documentView = text
        scroll.contentView.scroll(to: .zero)
        text.install(presentation: TelegramMessagePresentation.attributedString(value), value: value,
            key: .init(context: "synthetic-inline", value: value), canCopy: true,
            customEmojiDescriptors: [descriptor.fileID: descriptor], customEmojiContext: context)
        text.layoutSubtreeIfNeeded()
        guard provider.requests.count == 1 else { XCTFail("Visible reading row must start one native request"); return }
        scroll.contentView.scroll(to: .init(x: 0, y: 200))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertTrue(provider.leases[0].cancelled)
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertEqual(provider.requests.count, 2)
    }
    private func editor(_ state: InputState) -> (NativeTelegramText.Coordinator, UndoText) {
        let coordinator = NativeTelegramText.Coordinator(
            value: Binding(get: { state.input.formattedText }, set: { _ in }),
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            height: Binding(get: { state.height }, set: { state.height = $0 }),
            selection: state.input.selection, inputChanged: { state.input = $0 })
        let text = UndoText(frame: .init(x: 0, y: 0, width: 200, height: 80))
        text.allowsUndo = true; text.isEditable = true; text.delegate = coordinator
        text.nativeUndo.groupsByEvent = false
        coordinator.install(state.input.formattedText, in: text)
        return (coordinator, text)
    }
    // Catches bypassing the existing native undo/report path when a picker
    // inserts Unicode plus its typed entity into a rich selection.
    func testPickerInsertionUsesNativeUndoRedoAndPreservesTypedEntities() throws {
        let descriptor = try uiEmojiDescriptor(), contextID = UUID()
        let original = try TelegramComposerInput(formattedText: .init(text: "axb",
            entities: [.init(offset: 0, length: 3, kind: .bold)]), selection: .init(location: 1, length: 1))
        let state = InputState(original), (coordinator, text) = editor(state)
        let request = TelegramCustomEmojiInsertionRequest(descriptor: descriptor, expectedInput: original, contextID: contextID)
        var consumed = 0
        text.nativeUndo.beginUndoGrouping()
        coordinator.insertCustomEmoji(request, contextID: contextID, in: text) { _, input in
            consumed += 1; return input == original
        }
        text.nativeUndo.endUndoGrouping()
        let expected = try TelegramCustomEmojiInsertion.applying(descriptor, to: original)
        guard state.input == expected else { XCTFail("Native picker insertion must publish complete text/entities/selection"); return }
        XCTAssertEqual(consumed, 1); XCTAssertEqual(text.string, "a🦊b")
        XCTAssertTrue(text.nativeUndo.canUndo)
        text.nativeUndo.undo(); XCTAssertEqual(state.input, original)
        text.nativeUndo.redo(); XCTAssertEqual(state.input, expected)
        XCTAssertEqual(consumed, 1)
        coordinator.detach()
    }
    // Catches a late picker result applying after native selection changed or
    // after the chat context was rebound, even if the string is identical.
    func testChangedNativeSelectionOrContextRefusesPickerInsertionBeforeConsume() throws {
        let descriptor = try uiEmojiDescriptor(), contextID = UUID()
        let original = try TelegramComposerInput(formattedText: .init(text: "ab"), selection: .init(location: 1, length: 0))
        let state = InputState(original), (coordinator, text) = editor(state)
        let request = TelegramCustomEmojiInsertionRequest(descriptor: descriptor, expectedInput: original, contextID: contextID)
        text.setSelectedRange(.init(location: 0, length: 0))
        var consumed = 0
        coordinator.insertCustomEmoji(request, contextID: contextID, in: text) { _, _ in consumed += 1; return true }
        text.setSelectedRange(.init(location: 1, length: 0))
        coordinator.insertCustomEmoji(.init(descriptor: descriptor, expectedInput: original, contextID: contextID),
            contextID: UUID(), in: text) { _, _ in consumed += 1; return true }
        XCTAssertEqual(text.string, "ab"); XCTAssertEqual(consumed, 0); XCTAssertFalse(text.nativeUndo.canUndo)
        coordinator.detach()
    }
    // Catches admission rejection still mutating native input, and replaying a
    // consumed request after Undo returns to the same source snapshot.
    func testAdmissionRejectionAndConsumedRequestReplayDoNotEditNativeText() throws {
        let descriptor = try uiEmojiDescriptor(), contextID = UUID()
        let original = try TelegramComposerInput(formattedText: .init(text: "ab"), selection: .init(location: 1, length: 0))
        let state = InputState(original), (coordinator, text) = editor(state)
        let rejected = TelegramCustomEmojiInsertionRequest(descriptor: descriptor, expectedInput: original, contextID: contextID)
        coordinator.insertCustomEmoji(rejected, contextID: contextID, in: text) { _, _ in false }
        XCTAssertEqual(text.string, "ab"); XCTAssertFalse(text.nativeUndo.canUndo)
        let accepted = TelegramCustomEmojiInsertionRequest(descriptor: descriptor, expectedInput: original, contextID: contextID)
        text.nativeUndo.beginUndoGrouping()
        coordinator.insertCustomEmoji(accepted, contextID: contextID, in: text) { _, _ in true }
        text.nativeUndo.endUndoGrouping()
        guard text.string == "a🦊b" else { XCTFail("Current admitted insertion must edit native text"); return }
        text.nativeUndo.undo(); XCTAssertEqual(text.string, "ab")
        var reconsumed = false
        coordinator.insertCustomEmoji(accepted, contextID: contextID, in: text) { _, _ in reconsumed = true; return true }
        XCTAssertEqual(text.string, "ab"); XCTAssertFalse(reconsumed)
        coordinator.detach()
    }
    #if DEBUG
    private final class CatalogProvider: TelegramCustomEmojiCatalogProvider {
        let accountID: Int64
        let descriptor: TelegramCustomEmojiDescriptor
        init(accountID: Int64 = -1, descriptor: TelegramCustomEmojiDescriptor) {
            self.accountID = accountID; self.descriptor = descriptor
        }
        func catalog() -> Signal<TelegramCustomEmojiCatalogSnapshot, NoError> {
            .single(.init(accountID: accountID, entitlement: .standard, recent: [descriptor], installed: [], featured: []))
        }
        func search(query: String) -> Signal<TelegramCustomEmojiSearchResult, NoError> { .single(.init(items: [], isFinal: true)) }
        func loadPack(reference: TelegramStickerPackReference) -> Signal<TelegramCustomEmojiPackResult, NoError> { .single(.unavailable) }
        func setInstalled(pack: TelegramCustomEmojiPack, installed: Bool) -> Signal<Bool, NoError> { .single(false) }
    }
    // Catches model admission accepting an arbitrary Codable descriptor, or
    // consume mutating text outside the editor's native undo transaction.
    func testModelAdmitsOnlyCurrentCatalogPickAndConsumesWithoutChangingInput() throws {
        let descriptor = try uiEmojiDescriptor(), model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001; model.draft = "base"
        model.customEmojiCatalog.bind(provider: CatalogProvider(descriptor: descriptor))
        let original = model.composerInput, context = model.messageActionContextID
        let admitted = model.requestCustomEmojiInsertion(descriptor: descriptor,
            catalogContextID: model.customEmojiCatalog.contextID, expectedInput: original,
            contextID: context, chatID: 10001, expectedRevision: model.composerInputRevision)
        guard admitted, let request = model.customEmojiInsertion else { XCTFail("Current native catalog pick must produce a bound request"); return }
        XCTAssertEqual(request.expectedInput, original); XCTAssertEqual(request.contextID, context)
        XCTAssertTrue(model.consumeCustomEmojiInsertion(id: request.id, expectedInput: original))
        XCTAssertNil(model.customEmojiInsertion); XCTAssertEqual(model.composerInput, original)
        XCTAssertFalse(model.consumeCustomEmojiInsertion(id: request.id, expectedInput: original))
        model.customEmojiCatalog.bind(provider: nil)
        XCTAssertFalse(model.requestCustomEmojiInsertion(descriptor: descriptor, catalogContextID: UUID(),
            expectedInput: original, contextID: context, chatID: 10001, expectedRevision: model.composerInputRevision))
    }
    // Catches ABA draft edits and stale picker authority across topic, chat or
    // account changes even when displayed source text/selection is identical.
    func testModelRefusesStaleRevisionTopicChatAndForeignAccountPicker() throws {
        let descriptor = try uiEmojiDescriptor(), model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001; model.draft = "base"
        model.customEmojiCatalog.bind(provider: CatalogProvider(descriptor: descriptor))
        let input = model.composerInput, revision = model.composerInputRevision
        let context = model.messageActionContextID, catalog = model.customEmojiCatalog.contextID
        model.draft = "intervening edit"; model.draft = "base"
        XCTAssertEqual(model.composerInput, input); XCTAssertNotEqual(model.composerInputRevision, revision)
        XCTAssertFalse(model.requestCustomEmojiInsertion(descriptor: descriptor, catalogContextID: catalog,
            expectedInput: input, contextID: context, chatID: 10001, expectedRevision: revision))
        guard model.requestCustomEmojiInsertion(descriptor: descriptor, catalogContextID: catalog,
            expectedInput: input, contextID: context, chatID: 10001, expectedRevision: model.composerInputRevision),
              let request = model.customEmojiInsertion else { XCTFail("Current pick must be admitted before exercising stale context"); return }
        let topic = TelegramForumTopic(accountID: -1, chatID: 10001, threadID: 7, title: "Synthetic topic")
        model.forumTopics.bind(accountID: -1, provider: { _ in .single(.success(.init(accountID: -1,
            chatID: 10001, topics: [topic], isLoading: false))) })
        model.forumTopics.setVisible(true); model.forumTopics.selectChat(10001)
        XCTAssertTrue(model.selectForumTopic(topic, contextID: context))
        XCTAssertFalse(model.consumeCustomEmojiInsertion(id: request.id, expectedInput: input))
        XCTAssertFalse(model.requestCustomEmojiInsertion(descriptor: descriptor, catalogContextID: catalog,
            expectedInput: input, contextID: context, chatID: 10001, expectedRevision: revision))
        model.selectedChatID = 10002
        XCTAssertFalse(model.requestCustomEmojiInsertion(descriptor: descriptor, catalogContextID: catalog,
            expectedInput: model.composerInput, contextID: model.messageActionContextID, chatID: 10001,
            expectedRevision: model.composerInputRevision))
        model.customEmojiCatalog.bind(provider: CatalogProvider(accountID: 2, descriptor: descriptor))
        XCTAssertFalse(model.requestCustomEmojiInsertion(descriptor: descriptor,
            catalogContextID: model.customEmojiCatalog.contextID, expectedInput: model.composerInput,
            contextID: model.messageActionContextID, chatID: 10002, expectedRevision: model.composerInputRevision))
    }
    #endif
    private func emojiValue(_ descriptor: TelegramCustomEmojiDescriptor) throws -> TelegramFormattedText {
        try .init(text: "🦊", entities: [.init(offset: 0, length: 2, kind: .customEmoji(stickerPack: nil, fileID: descriptor.fileID))])
    }
}
private nonisolated func uiEmojiDescriptor() throws -> TelegramCustomEmojiDescriptor {
    try .init(file: TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: 100),
        partialReference: nil, resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 100, accessHash: 53,
            size: 36, fileReference: Data([1,2]), fileName: "synthetic-emoji.webp"),
        previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/webp", size: 36,
        attributes: [.CustomEmoji(isPremium: false, isSingleColor: false, alt: "🦊", packReference: nil)], alternativeRepresentations: []))
}

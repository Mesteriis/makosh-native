import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramCustomEmojiModelResolutionTests: XCTestCase {
    private final class EmptyCatalog: TelegramCustomEmojiCatalogProvider {
        let accountID: Int64 = -1
        func catalog() -> Signal<TelegramCustomEmojiCatalogSnapshot, NoError> {
            .single(.init(accountID: accountID, entitlement: .standard, recent: [], installed: [], featured: []))
        }
        func search(query: String) -> Signal<TelegramCustomEmojiSearchResult, NoError> { .single(.init(items: [], isFinal: true)) }
        func loadPack(reference: TelegramStickerPackReference) -> Signal<TelegramCustomEmojiPackResult, NoError> { .single(.unavailable) }
        func setInstalled(pack: TelegramCustomEmojiPack, installed: Bool) -> Signal<Bool, NoError> { .single(false) }
    }
    private func modelWithoutCatalogEmoji() -> TelegramModel {
        let model = TelegramModel.syntheticExtendedMessagesPreview()
        model.selectedChatID = 10004
        model.customEmojiCatalog.bind(provider: nil)
        model.customEmojiCatalog.bind(provider: EmptyCatalog())
        return model
    }
    private func input() throws -> TelegramComposerInput {
        try .init(formattedText: .init(text: "🦊", entities: [
            .init(offset: 0, length: 2, kind: .customEmoji(stickerPack: nil, fileID: 901))]))
    }
    // A restored caption can reference a document absent from both the current
    // catalog and history. Resolving it must not depend on opening its pack.
    func testUploadCaptionResolvesItsDocumentThenReleasesItAfterRemoval() async throws {
        let model = modelWithoutCatalogEmoji()
        XCTAssertNil(model.customEmojiDescriptors[901])
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("synthetic caption".utf8).write(to: source)
        defer { model.upload.clear(); try? FileManager.default.removeItem(at: source) }
        model.upload.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false,
            target: .init(accountID: -1, chatID: 10004, title: "Synthetic"), captionInput: try input(),
            captionPolicy: try .init(maximumUTF16Count: 2048))
        for _ in 0..<100 {
            if model.upload.phase == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.upload.phase, .ready)
        XCTAssertNotNil(model.customEmojiDescriptors[901], "Caption-only custom document must reach the common renderer")
        XCTAssertTrue(model.upload.updateCaptionInput(.empty, contextID: model.upload.captionContextID))
        XCTAssertNil(model.customEmojiDescriptors[901], "Removing the caption must release its historical descriptor")
    }
    // Inline edit drafts may contain emoji removed from the visible message
    // history or pack. Closing the edit must drop that independent render lease.
    func testInlineEditResolvesItsDocumentAndDropsItWhenClosed() throws {
        let model = modelWithoutCatalogEmoji(), value = try input()
        XCTAssertNil(model.customEmojiDescriptors[901])
        let source = TelegramMessageActionSource(metadata: .init(peerID: 10004, namespace: 0,
            messageID: 1, fingerprint: "synthetic edit", text: value.formattedText.text,
            authorID: -1, canReply: true, canEdit: true, canForward: true,
            canDeleteLocally: true, canDeleteForEveryone: true, formattedText: value.formattedText),
            accountID: -1, chatID: 10004)
        XCTAssertTrue(model.beginMessageEdit(source: source, author: "Synthetic", contextID: model.messageActionContextID))
        let edit = try XCTUnwrap(model.messageEditSession)
        XCTAssertNotNil(model.customEmojiDescriptors[901], "Inline edit must resolve its own document")
        XCTAssertTrue(model.cancelMessageEdit(sessionID: edit.id, contextID: edit.contextID))
        XCTAssertNil(model.customEmojiDescriptors[901])
    }
    func testNewForumSnapshotResolvesItsIconBeforeAnotherComposerEdit() throws {
        let model = modelWithoutCatalogEmoji()
        XCTAssertNil(model.customEmojiDescriptors[901])
        model.forumTopics.bind(accountID: -1, provider: { chatID in
            .single(.success(.init(accountID: -1, chatID: chatID, topics: [
                .init(accountID: -1, chatID: chatID, threadID: 7, title: "Synthetic icon", iconFileID: 901)
            ], isLoading: false)))
        })
        model.forumTopics.setVisible(true)
        model.forumTopics.selectChat(10004)
        XCTAssertNotNil(model.forumTopics.snapshot?.topics.first)
        XCTAssertNotNil(model.customEmojiDescriptors[901], "Published emits the new icon before the stored snapshot changes")
    }
}

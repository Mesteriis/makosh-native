import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramCaptionEditPlacementTests: XCTestCase {
    private func native(text: String = "Caption", above: Bool, media: Bool = true, nonvisual: Bool = false) -> Message {
        let peerID = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42))
        let user = TelegramUser(id: peerID, accessHash: nil, firstName: "Synthetic", lastName: nil,
            username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
            emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
            profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        var peers = SimpleDictionary<PeerId, Peer>(); peers[peerID] = user
        let photo = TelegramMediaImage(imageId: MediaId(namespace: 0, id: 1), representations: [],
            immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        let file = TelegramMediaFile(fileId: MediaId(namespace: 0, id: 2), partialReference: nil,
            resource: EmptyMediaResource(), previewRepresentations: [], videoThumbnails: [],
            immediateThumbnailData: nil, mimeType: "application/pdf", size: nil, attributes: [], alternativeRepresentations: [])
        return Message(stableId: 1, stableVersion: 0, id: MessageId(peerId: peerID, namespace: 0, id: 1),
            globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 1,
            flags: [], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil,
            author: user, text: text, attributes: above ? [InvertMediaMessageAttribute()] : [],
            media: media ? [nonvisual ? file : photo] : [], peers: peers, associatedMessages: SimpleDictionary(),
            associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
    }
    private func source(_ message: Message) -> TelegramMessageActionSource {
        telegramMessageActionSource(message, accountID: 42, chatID: 42)
    }

    func testLegacyTextAndRichEditsPreserveNativePlacementInRequestContent() throws {
        let original = source(native(above: true))
        XCTAssertTrue(original.metadata.hasMedia); XCTAssertTrue(original.metadata.captionAboveMedia)
        let plain = try XCTUnwrap(TelegramMessageEditContent(action: .edit("New caption"), source: original))
        XCTAssertEqual(plain.formatted.text, "New caption"); XCTAssertNotNil(plain.invertMediaAttribute)
        let rich = try TelegramFormattedText(text: "New caption", entities: [.init(offset: 0, length: 3, kind: .bold)])
        let value = try XCTUnwrap(TelegramMessageEditContent(action: .editFormatted(rich), source: original))
        XCTAssertEqual(value.formatted.engineEntities(), [.init(range: 0..<3, type: .Bold)])
        XCTAssertNotNil(value.invertMediaAttribute)
        let below = try XCTUnwrap(TelegramMessageEditContent(action: .editFormatted(rich, captionAboveMedia: false), source: original))
        XCTAssertNil(below.invertMediaAttribute)
        XCTAssertNil(TelegramMessageEditContent(action: .delete(forEveryone: false), source: original))
    }

    func testPlacementOnlyIsAnEditButNoopPlainTextAndInvalidCaptionAreRefused() throws {
        let original = source(native(above: true)), caption = try TelegramFormattedText(text: "Caption")
        XCTAssertTrue(telegramMessageActionAllowed(.editFormatted(caption, captionAboveMedia: false), source: original))
        XCTAssertFalse(telegramMessageActionAllowed(.editFormatted(caption, captionAboveMedia: true), source: original))
        XCTAssertFalse(telegramMessageActionAllowed(.editFormatted(caption), source: original))
        XCTAssertFalse(telegramMessageActionAllowed(.editFormatted(try .init(text: "Changed"), captionAboveMedia: true), source: source(native(above: false, media: false))))
        XCTAssertFalse(telegramMessageActionAllowed(.editFormatted(try .init(text: String(repeating: "x", count: 1025)), captionAboveMedia: false), source: original))
        let empty = source(native(text: "", above: true))
        XCTAssertTrue(empty.metadata.captionAboveMedia)
        XCTAssertTrue(telegramMessageActionAllowed(.editFormatted(try .init(text: ""), captionAboveMedia: false), source: empty))
    }

    func testReconciliationRequiresExactPlacementAsWellAsTextAndEntities() throws {
        let content = try XCTUnwrap(TelegramMessageEditContent(action: .editFormatted(try .init(text: "Caption"), captionAboveMedia: false), source: source(native(above: true))))
        XCTAssertTrue(content.matches(native(above: false)))
        XCTAssertFalse(content.matches(native(above: true)), "An unchanged text acknowledgement must not hide a failed placement change")
        XCTAssertFalse(content.matches(native(text: "Other", above: false)))
        let rich = try TelegramFormattedText(text: "Caption", entities: [.init(offset: 0, length: 7, kind: .bold)])
        let formatted = try XCTUnwrap(TelegramMessageEditContent(action: .editFormatted(rich), source: source(native(above: true))))
        XCTAssertFalse(formatted.matches(native(above: true)), "Matching text and placement must not hide dropped entities")
    }

    func testNonvisualFileEditPreservesRawNativePlacementEvenWhenPresentationIsBelow() throws {
        let message = native(above: true, nonvisual: true)
        XCTAssertFalse(TelegramMessage(message).captionAboveMedia)
        let content = try XCTUnwrap(TelegramMessageEditContent(action: .edit("Changed"), source: source(message)))
        XCTAssertNotNil(content.invertMediaAttribute)
        XCTAssertTrue(content.matches(native(text: "Changed", above: true, nonvisual: true)))
        XCTAssertFalse(content.matches(native(text: "Changed", above: false, nonvisual: true)))
    }
}

#if DEBUG
@MainActor final class TelegramCaptionEditSessionTests: XCTestCase {
    private final class Lease: TelegramMessageActionsLease { func cancel() {} }
    private final class Provider: TelegramMessageActionsProvider {
        let accountID: Int64 = -1
        var callback: (@MainActor (TelegramMessageActionEvent) -> Void)?
        func start(action: TelegramMessageAction, source: TelegramMessageActionSource,
                   receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
            callback = receive; return Lease()
        }
    }
    private func source(above: Bool = true, media: Bool = true, fingerprint: String = "caption-v1") -> TelegramMessageActionSource {
        .init(metadata: .init(peerID: 10001, namespace: 0, messageID: 130, fingerprint: fingerprint,
            text: "Caption", authorID: -1, canReply: true, canEdit: true, canForward: true,
            canDeleteLocally: true, canDeleteForEveryone: true, allowsEmptyEdit: media,
            editLimit: media ? 1024 : 4096, hasMedia: media, captionAboveMedia: above), accountID: -1, chatID: 10001)
    }
    private func fixture(_ source: TelegramMessageActionSource? = nil) throws -> (TelegramModel, Provider, TelegramMessageEditSession) {
        let model = TelegramModel.syntheticPreview(), provider = Provider()
        model.selectedChatID = 10001; model.draft = "Ordinary stays"; model.messageActions.bind(provider: provider)
        XCTAssertTrue(model.beginMessageEdit(source: source ?? self.source(), author: "Synthetic", contextID: model.messageActionContextID))
        return (model, provider, try XCTUnwrap(model.messageEditSession))
    }
    func testPlacementSurvivesInputAndChatChangesWhileStaleMenuIsRefused() throws {
        let (model, _, initial) = try fixture()
        XCTAssertTrue(initial.captionAboveMedia); XCTAssertFalse(initial.canSubmit)
        XCTAssertTrue(model.updateMessageEditCaptionPlacement(false, sessionID: initial.id, revision: initial.revision, contextID: initial.contextID))
        let moved = try XCTUnwrap(model.messageEditSession)
        XCTAssertFalse(moved.captionAboveMedia); XCTAssertTrue(moved.canSubmit); XCTAssertNotEqual(initial.revision, moved.revision)
        XCTAssertFalse(model.updateMessageEditCaptionPlacement(true, sessionID: initial.id, revision: initial.revision, contextID: initial.contextID))
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Edited", entities: [.init(offset: 0, length: 6, kind: .bold)]), selection: .init(location: 2, length: 2))
        XCTAssertTrue(model.updateMessageEditInput(input, sessionID: initial.id, contextID: initial.contextID))
        let edited = try XCTUnwrap(model.messageEditSession); XCTAssertFalse(edited.captionAboveMedia)
        model.selectedChatID = 10002
        XCTAssertFalse(model.updateMessageEditCaptionPlacement(true, sessionID: edited.id, revision: edited.revision, contextID: edited.contextID))
        model.selectedChatID = 10001
        XCTAssertEqual(model.messageEditSession, edited); XCTAssertEqual(model.draft, "Ordinary stays")
    }
    func testPlacementOnlySubmissionAndNewerRevisionSurviveOldAcknowledgement() throws {
        let (model, provider, initial) = try fixture()
        _ = model.updateMessageEditCaptionPlacement(false, sessionID: initial.id, revision: initial.revision, contextID: initial.contextID)
        let moved = try XCTUnwrap(model.messageEditSession)
        XCTAssertFalse(model.submitMessageEdit(sessionID: moved.id, revision: initial.revision, contextID: moved.contextID))
        XCTAssertTrue(model.submitMessageEdit(sessionID: moved.id, revision: moved.revision, contextID: moved.contextID))
        XCTAssertEqual(model.messageActions.action, .editFormatted(try .init(text: "Caption"), captionAboveMedia: false))
        XCTAssertFalse(model.updateMessageEditCaptionPlacement(true, sessionID: moved.id, revision: moved.revision, contextID: moved.contextID))
        let newer = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Newer edit"))
        _ = model.updateMessageEditInput(newer, sessionID: moved.id, contextID: moved.contextID)
        let retained = model.messageEditSession
        provider.callback?(.applied)
        XCTAssertEqual(model.messageEditSession, retained); XCTAssertEqual(model.draft, "Ordinary stays")
    }
    func testExactAcknowledgementClosesSessionCancelReopenUsesSourceAndPlainTextCannotMove() throws {
        let (model, provider, initial) = try fixture()
        _ = model.updateMessageEditCaptionPlacement(false, sessionID: initial.id, revision: initial.revision, contextID: initial.contextID)
        let moved = try XCTUnwrap(model.messageEditSession)
        XCTAssertTrue(model.submitMessageEdit(sessionID: moved.id, revision: moved.revision, contextID: moved.contextID))
        provider.callback?(.applied); XCTAssertNil(model.messageEditSession); XCTAssertEqual(model.draft, "Ordinary stays")
        XCTAssertTrue(model.beginMessageEdit(source: initial.source, author: "Synthetic", contextID: initial.contextID))
        let reopened = try XCTUnwrap(model.messageEditSession); XCTAssertTrue(reopened.captionAboveMedia)
        XCTAssertTrue(model.cancelMessageEdit(sessionID: reopened.id, contextID: reopened.contextID))
        let (plainModel, _, plain) = try fixture(source(above: false, media: false))
        XCTAssertFalse(plainModel.updateMessageEditCaptionPlacement(true, sessionID: plain.id, revision: plain.revision, contextID: plain.contextID))
    }

    func testStaleDirectEditCannotBypassCurrentCaptionPlacementAndUncertaintyLocksMenu() throws {
        let (model, provider, initial) = try fixture()
        _ = model.updateMessageEditCaptionPlacement(false, sessionID: initial.id, revision: initial.revision, contextID: initial.contextID)
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Edited"))
        _ = model.updateMessageEditInput(input, sessionID: initial.id, contextID: initial.contextID)
        let current = try XCTUnwrap(model.messageEditSession)
        XCTAssertFalse(model.performMessageAction(.editFormatted(input.formattedText), source: initial.source, contextID: initial.contextID))
        XCTAssertEqual(model.messageActions.phase, .idle)
        XCTAssertTrue(model.submitMessageEdit(sessionID: current.id, revision: current.revision, contextID: current.contextID))
        provider.callback?(.uncertain)
        XCTAssertFalse(model.updateMessageEditCaptionPlacement(true, sessionID: current.id, revision: current.revision, contextID: current.contextID))
        XCTAssertEqual(model.messageEditSession, current)
    }

    func testSyntheticCaptionMetadataAdmitsPlacementOnlyButPlainTextDoesNot() throws {
        let messages = TelegramSyntheticPages().messages(chatID: 10001, anchor: nil).items
        let photo = try XCTUnwrap(messages.first { $0.actionMetadata?.messageID == 130 })
        let metadata = try XCTUnwrap(photo.actionMetadata)
        XCTAssertTrue(metadata.hasMedia); XCTAssertFalse(metadata.captionAboveMedia)
        let source = TelegramMessageActionSource(metadata: metadata, accountID: -1, chatID: 10001)
        XCTAssertTrue(telegramMessageActionAllowed(.editFormatted(try .init(text: photo.text), captionAboveMedia: true), source: source))
        XCTAssertFalse(try XCTUnwrap(messages.first { $0.actionMetadata?.messageID == 122 }?.actionMetadata).hasMedia)
    }
}
#endif

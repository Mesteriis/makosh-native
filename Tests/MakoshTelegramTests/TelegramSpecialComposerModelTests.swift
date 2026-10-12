#if DEBUG
import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramSpecialComposerModelTests: XCTestCase {
    func testForumAllMessagesRequiresATopicBeforeOfferingSendOrAttachments() throws {
        let model = TelegramModel.syntheticExtendedMessagesPreview()
        model.forumTopics.setVisible(true)
        model.draft = "Retained all-messages draft"
        XCTAssertNil(model.selectedThreadID)
        XCTAssertFalse(model.composerCanSend)
        XCTAssertFalse(model.composerSupportsAttachments)
        let topic = try XCTUnwrap(model.forumTopics.snapshot?.topics.first { $0.threadID == 7 })
        XCTAssertTrue(model.selectForumTopic(topic, contextID: model.messageActionContextID))
        model.draft = "Topic draft"
        XCTAssertTrue(model.composerCanSend)
        XCTAssertTrue(model.composerSupportsAttachments)
        model.showForumAllMessages()
        XCTAssertEqual(model.draft, "Retained all-messages draft")
        XCTAssertFalse(model.composerCanSend)
        XCTAssertFalse(model.composerSupportsAttachments)
    }
    func testSecretComposerOffersOnlyTheSupportedPlainTextBoundary() throws {
        let model = TelegramModel.syntheticExtendedMessagesPreview(specialConversation: "secret")
        XCTAssertNotNil(model.conversationCapabilities?.secret)
        model.draft = "Plain text"
        XCTAssertTrue(model.composerCanSend)
        XCTAssertFalse(model.composerSupportsCustomEmoji)
        XCTAssertFalse(model.composerSupportsAttachments)
        model.draft = ""
        XCTAssertFalse(model.canStartVoiceRecording)
        let formatted = try TelegramComposerInput(formattedText: .init(text: "Rich", entities: [
            .init(offset: 0, length: 4, kind: .bold)]))
        XCTAssertTrue(model.updateComposerInput(formatted, contextID: model.messageActionContextID, chatID: 10002))
        XCTAssertFalse(model.composerCanSend)
    }
    func testKnownSecretNamespaceDisablesRichComposerBeforeCapabilitiesLoad() {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = PeerId(namespace: Namespaces.Peer.SecretChat,
            id: ._internalFromInt64Value(21)).toInt64()
        XCTAssertNil(model.conversationCapabilities)
        XCTAssertFalse(model.composerSupportsCustomEmoji)
        XCTAssertFalse(model.composerSupportsAttachments)

        model.selectedChatID = 10001
        XCTAssertNil(model.conversationCapabilities)
        XCTAssertTrue(model.composerSupportsCustomEmoji)
        XCTAssertTrue(model.composerSupportsAttachments)
    }
}
#endif

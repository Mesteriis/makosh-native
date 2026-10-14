#if DEBUG
import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

@MainActor final class TelegramSecretModelTests: XCTestCase {
    func testNativeSecretComposerRequiresCurrentActiveSessionAndLayer() throws {
        let model = TelegramModel.syntheticSecretChatsPreview()
        let id = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(44)).toInt64()
        model.selectedChatID = id
        model.draft = "Text"
        XCTAssertTrue(model.composerCanSend); XCTAssertTrue(model.composerSupportsAttachments)
        XCTAssertTrue(model.composerSupportsCustomEmoji); XCTAssertEqual(model.uploadTarget?.chatID, id)
        let rich = try TelegramComposerInput(formattedText: .init(text: "Rich", entities: [.init(offset: 0, length: 4, kind: .bold)]))
        XCTAssertTrue(model.updateComposerInput(rich, contextID: model.messageActionContextID, chatID: id))
        XCTAssertTrue(model.composerCanSend)
        model.secretChats.bind(nil)
        XCTAssertFalse(model.composerCanSend); XCTAssertFalse(model.composerSupportsAttachments); XCTAssertFalse(model.composerSupportsCustomEmoji)
    }
    func testSecretCreationRequiresExactCurrentPersonProfileAndNavigatesToNativeSecretID() async throws {
        let model = TelegramModel.syntheticSecretChatsPreview()
        model.selectedChatID = 42; model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Missing isolated profile") }
        XCTAssertFalse(model.openSecretChatCreation(profile, contextID: UUID()))
        XCTAssertTrue(model.openSecretChatCreation(profile, contextID: model.contactProfileContextID))
        let basis = try XCTUnwrap(model.secretChats.creationBasis)
        XCTAssertTrue(model.secretChats.create(basis: basis, contextID: model.secretChats.creationContextID))
        for _ in 0..<300 where model.selectedChatID == 42 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(model.selectedChatID, 42); XCTAssertNotNil(model.conversationCapabilities?.secret)
        XCTAssertEqual(model.secretChats.session?.state, .handshake)
        XCTAssertFalse(model.composerCanSend); XCTAssertFalse(model.composerSupportsAttachments)
    }
    func testCancelledProfileCannotAuthorizeSecretCreation() {
        let model = TelegramModel.syntheticSecretChatsPreview()
        model.selectedChatID = 42; model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Missing isolated profile") }
        let context = model.contactProfileContextID
        model.cancelContactProfile()
        XCTAssertFalse(model.openSecretChatCreation(profile, contextID: context))
    }
    func testSecretReplyRemainsBoundToSelectedNativeChatWithoutCloudQuote() throws {
        let model = TelegramModel.syntheticSecretChatsPreview()
        let id = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(44)).toInt64()
        model.selectedChatID = id
        let message = try XCTUnwrap(model.messages.first), source = try XCTUnwrap(model.actionSource(for: message))
        let quote = try XCTUnwrap(TelegramReplyQuote(source: try TelegramFormattedText(text: message.text), selection: .init(location: 0, length: 4)))
        XCTAssertNil(source.quoting(quote), "Encrypted reply cannot carry a cloud text-selection quote")
        XCTAssertTrue(model.beginReply(to: message, contextID: model.messageActionContextID))
        XCTAssertNotNil(model.composerReply.resolved)
        model.draft = "Reply"
        XCTAssertTrue(model.composerCanSend)
        model.selectedChatID = 42
        XCTAssertNil(model.composerReply.resolved)
    }
}
#endif

#if DEBUG
import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramForumModelTests: XCTestCase {
    private func fixture() -> (TelegramModel, TelegramForumTopic, TelegramForumTopic) {
        let model = TelegramModel.syntheticPreview()
        let a = TelegramForumTopic(accountID: -1, chatID: 10001, threadID: 1, title: "General")
        let b = TelegramForumTopic(accountID: -1, chatID: 10001, threadID: 7, title: "Design")
        model.selectedChatID = 10001
        model.forumTopics.bind(accountID: -1, provider: { _ in .single(.success(.init(accountID: -1, chatID: 10001, topics: [a,b], isLoading: false))) })
        model.forumTopics.setVisible(true); model.forumTopics.selectChat(10001)
        return (model,a,b)
    }
    func testTopicSwitchKeepsExactDraftAndRejectsOldEditorCallbacks() {
        let (model,a,b) = fixture()
        model.draft = "Common"
        let commonContext = model.messageActionContextID
        XCTAssertTrue(model.selectForumTopic(a, contextID: commonContext))
        XCTAssertEqual(model.selectedThreadID, 1); XCTAssertEqual(model.draft, "")
        model.draft = "General 😀"
        let topicContext = model.messageActionContextID
        XCTAssertNotEqual(topicContext, commonContext)
        XCTAssertTrue(model.selectForumTopic(b, contextID: topicContext))
        model.draft = "Design"
        XCTAssertFalse(model.updateComposerInput(try! .init(formattedText: .init(text: "late old editor")), contextID: topicContext, chatID: 10001))
        XCTAssertEqual(model.draft, "Design")
        XCTAssertTrue(model.selectForumTopic(a, contextID: model.messageActionContextID))
        XCTAssertEqual(model.draft, "General 😀")
        model.showForumAllMessages()
        XCTAssertNil(model.selectedThreadID); XCTAssertEqual(model.draft, "Common")
    }
    func testTopicSelectionRejectsForeignIdentityStaleContextAndUnobservedTopic() {
        let (model,a,_) = fixture(), context = model.messageActionContextID
        for foreign in [TelegramForumTopic(accountID: 9, chatID: 10001, threadID: 1, title: "General"),
            TelegramForumTopic(accountID: -1, chatID: 10002, threadID: 1, title: "General"),
            TelegramForumTopic(accountID: -1, chatID: 10001, threadID: 9, title: "Unknown")] {
            XCTAssertFalse(model.selectForumTopic(foreign, contextID: context))
        }
        XCTAssertTrue(model.selectForumTopic(a, contextID: context))
        XCTAssertFalse(model.selectForumTopic(a, contextID: context))
        XCTAssertEqual(model.selectedThreadID, 1)
        model.selectedChatID = 10002
        XCTAssertNil(model.selectedThreadID)
    }
    func testTopicUploadTargetUsesSelectedIdentityWithoutRequiringAReply() {
        let (model,a,_) = fixture()
        XCTAssertTrue(model.selectForumTopic(a, contextID: model.messageActionContextID))
        XCTAssertEqual(model.uploadTarget?.threadID, 1)
        XCTAssertNil(model.uploadTarget?.replySource)
        let previous = model.uploadContextID
        model.showForumAllMessages()
        XCTAssertNotEqual(previous, model.uploadContextID)
    }
}
#endif

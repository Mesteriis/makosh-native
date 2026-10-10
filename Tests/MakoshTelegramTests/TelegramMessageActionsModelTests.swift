#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramMessageActionsModelTests: XCTestCase {
    private final class Lease: TelegramMessageActionsLease { func cancel() {} }
    private final class Provider: TelegramMessageActionsProvider {
        let accountID: Int64 = -1
        var callback: (@MainActor (TelegramMessageActionEvent) -> Void)?
        var actions: [TelegramMessageAction] = []
        func start(action: TelegramMessageAction, source: TelegramMessageActionSource,
                   receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
            actions.append(action); callback = receive; return Lease()
        }
    }
    private func fixture() throws -> (TelegramModel, Provider, TelegramMessageActionSource) {
        let model = TelegramModel.syntheticPreview(), provider = Provider()
        model.selectedChatID = 10001
        model.messageActions.bind(provider: provider)
        let message = try XCTUnwrap(model.messages.last(where: { $0.isOutgoing }))
        return (model, provider, try XCTUnwrap(model.actionSource(for: message)))
    }
    func testReplyQueueAckClearsOnlyOriginalAccountChatDraft() throws {
        let (model, provider, source) = try fixture()
        model.draft = "frozen reply"
        XCTAssertTrue(model.performMessageAction(.reply(model.draft), source: source, contextID: model.messageActionContextID))
        model.selectedChatID = 10002; model.draft = "other chat draft"
        provider.callback?(.committing); provider.callback?(.queued)
        XCTAssertEqual(model.draft, "other chat draft")
        model.selectedChatID = 10001
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(provider.actions, [.reply("frozen reply")])
    }
    func testEditedComposerSurvivesCapturedReplyAckAndEditNeverClearsDraft() throws {
        let (model, provider, source) = try fixture()
        model.draft = "submitted"
        XCTAssertTrue(model.performMessageAction(.reply(model.draft), source: source, contextID: model.messageActionContextID))
        model.draft = "new composition"
        provider.callback?(.queued)
        XCTAssertEqual(model.draft, "new composition")
        XCTAssertTrue(model.performMessageAction(.edit("new source text"), source: source, contextID: model.messageActionContextID))
        provider.callback?(.applied)
        XCTAssertEqual(model.draft, "new composition")
    }
    func testRejectionUncertaintyAndContextChangesKeepCompositionAndBlockWrongTarget() throws {
        let (model, provider, source) = try fixture()
        model.draft = "keep me"
        let context = model.messageActionContextID
        XCTAssertTrue(model.performMessageAction(.reply(model.draft), source: source, contextID: context))
        provider.callback?(.rejected)
        XCTAssertEqual(model.draft, "keep me")
        model.selectedChatID = 10002
        XCTAssertFalse(model.performMessageAction(.reply("wrong"), source: source, contextID: context))
        model.selectedChatID = 10001
        XCTAssertTrue(model.performMessageAction(.reply(model.draft), source: source, contextID: context))
        provider.callback?(.committing); provider.callback?(.uncertain)
        XCTAssertEqual(model.draft, "keep me")
        XCTAssertFalse(model.performMessageAction(.reply(model.draft), source: source, contextID: context))
        model.disconnect()
        XCTAssertNotEqual(context, model.messageActionContextID)
        XCTAssertFalse(model.performMessageAction(.reply("stale"), source: source, contextID: context))
        XCTAssertEqual(provider.actions.count, 2)
    }
    func testForwardRequiresExplicitKnownDestinationAndSnapshotAccount() throws {
        let (model, provider, source) = try fixture()
        XCTAssertFalse(model.performMessageAction(.forward(destinationChatID: 777777), source: source, contextID: model.messageActionContextID))
        let foreign = TelegramMessageActionSource(metadata: source.metadata, accountID: 123, chatID: source.chatID)
        XCTAssertFalse(model.performMessageAction(.forward(destinationChatID: 10002), source: foreign, contextID: model.messageActionContextID))
        XCTAssertTrue(model.performMessageAction(.forward(destinationChatID: 10002), source: source, contextID: model.messageActionContextID))
        XCTAssertEqual(provider.actions, [.forward(destinationChatID: 10002)])
    }
    func testEditDraftRetainedAcrossRejectionResetAndUnrelatedAck() throws {
        let (model, provider, source) = try fixture()
        let context = model.messageActionContextID
        model.saveMessageEditDraft("retained edit", source: source, contextID: context)
        XCTAssertTrue(model.performMessageAction(.edit("retained edit"), source: source, contextID: context))
        provider.callback?(.rejected)
        XCTAssertEqual(model.messageEditDraft(for: source), "retained edit")
        model.messageActions.bind(provider: provider)
        XCTAssertEqual(model.messageEditDraft(for: source), "retained edit")
        XCTAssertTrue(model.performMessageAction(.edit("retained edit"), source: source, contextID: context))
        model.saveMessageEditDraft("newer edit", source: source, contextID: context)
        provider.callback?(.applied)
        XCTAssertEqual(model.messageEditDraft(for: source), "newer edit")
        XCTAssertTrue(model.performMessageAction(.edit("newer edit"), source: source, contextID: context))
        provider.callback?(.applied)
        XCTAssertEqual(model.messageEditDraft(for: source), source.text)
        let other = TelegramMessageActionSource(metadata: source.metadata, accountID: 999, chatID: source.chatID)
        XCTAssertEqual(model.messageEditDraft(for: other), source.text)
        model.saveMessageEditDraft("foreign", source: other, contextID: context)
        XCTAssertEqual(model.messageEditDraft(for: other), source.text)
    }
    func testFormattedDraftSurvivesRejectionAndNewerFormattingSurvivesAck() throws {
        let (model, provider, source) = try fixture()
        let bold = try TelegramFormattedText(text: "rich", entities: [.init(offset: 0, length: 4, kind: .bold)])
        let italic = try TelegramFormattedText(text: "rich", entities: [.init(offset: 0, length: 4, kind: .italic)])
        let context = model.messageActionContextID
        model.saveMessageFormattedEditDraft(bold, source: source, contextID: context)
        XCTAssertTrue(model.performMessageAction(.editFormatted(bold), source: source, contextID: context))
        provider.callback?(.rejected)
        XCTAssertEqual(model.messageFormattedEditDraft(for: source), bold)
        model.saveMessageEditDraft("plain must not flatten", source: source, contextID: context)
        XCTAssertEqual(model.messageFormattedEditDraft(for: source), bold)
        XCTAssertTrue(model.performMessageAction(.editFormatted(bold), source: source, contextID: context))
        model.saveMessageFormattedEditDraft(italic, source: source, contextID: context)
        provider.callback?(.applied)
        XCTAssertEqual(model.messageFormattedEditDraft(for: source), italic)
        XCTAssertTrue(model.performMessageAction(.editFormatted(italic), source: source, contextID: context))
        provider.callback?(.applied)
        XCTAssertEqual(model.messageFormattedEditDraft(for: source), source.metadata.formattedText)
    }
    func testRichSourceDraftPreservesEntitiesAndRejectsStaleContext() throws {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        let source = try XCTUnwrap(model.messages.first { $0.id == "synthetic:10001:122" }.flatMap(model.actionSource))
        let original = try XCTUnwrap(source.metadata.formattedText)
        XCTAssertEqual(model.messageFormattedEditDraft(for: source), original)
        model.saveMessageEditDraft("plain", source: source, contextID: model.messageActionContextID)
        XCTAssertEqual(model.messageFormattedEditDraft(for: source), original)
        model.saveMessageFormattedEditDraft(try TelegramFormattedText(text: "stale"), source: source, contextID: UUID())
        XCTAssertEqual(model.messageFormattedEditDraft(for: source), original)
    }
}
#endif

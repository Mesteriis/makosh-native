#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramMessageEditSessionTests: XCTestCase {
    private final class Lease: TelegramMessageActionsLease { func cancel() {} }
    private final class Provider: TelegramMessageActionsProvider {
        let accountID: Int64 = -1
        var callback: (@MainActor (TelegramMessageActionEvent) -> Void)?
        var synchronous = false
        func start(action: TelegramMessageAction, source: TelegramMessageActionSource,
                   receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
            callback = receive
            if synchronous { receive(.applied) }
            return Lease()
        }
    }
    private func source(chat: Int64 = 10001, fingerprint: String = "v1") -> TelegramMessageActionSource {
        .init(accountID: -1, chatID: chat, peerID: chat, namespace: 0, messageID: 7,
              fingerprint: fingerprint, text: "original", canReply: true, canEdit: true,
              canForward: true, canDeleteLocally: true, canDeleteForEveryone: true)
    }
    private func fixture() -> (TelegramModel, Provider) {
        let model = TelegramModel.syntheticPreview(), provider = Provider()
        model.selectedChatID = 10001
        model.messageActions.bind(provider: provider)
        return (model, provider)
    }
    private func input(_ text: String = "edited", selection: Int = 1, bold: Bool = true) throws -> TelegramComposerInput {
        try .init(formattedText: TelegramFormattedText(text: text,
            entities: bold ? [.init(offset: 0, length: 1, kind: .bold)] : []),
            selection: .init(location: selection, length: 0))
    }
    private func begin(_ model: TelegramModel, source: TelegramMessageActionSource? = nil) throws -> TelegramMessageEditSession {
        XCTAssertTrue(model.beginMessageEdit(source: source ?? self.source(), author: "Synthetic", contextID: model.messageActionContextID))
        return try XCTUnwrap(model.messageEditSession)
    }
    func testPerChatSessionsRetainFullInputAndOrdinaryDraft() throws {
        let (model, _) = fixture(); model.draft = "ordinary"
        let first = try begin(model), value = try input()
        XCTAssertTrue(model.updateMessageEditInput(value, sessionID: first.id, contextID: first.contextID))
        let changed = try XCTUnwrap(model.messageEditSession)
        XCTAssertNotEqual(first.revision, changed.revision)
        XCTAssertTrue(model.updateMessageEditInput(value, sessionID: first.id, contextID: first.contextID))
        XCTAssertEqual(model.messageEditSession?.revision, changed.revision)
        model.selectedChatID = 10002
        XCTAssertNil(model.messageEditSession)
        let other = try begin(model, source: source(chat: 10002))
        XCTAssertNotEqual(other.id, first.id)
        XCTAssertFalse(model.updateMessageEditInput(value, sessionID: first.id, contextID: first.contextID))
        model.selectedChatID = 10001
        XCTAssertEqual(model.messageEditSession, changed)
        XCTAssertEqual(model.draft, "ordinary")
        XCTAssertEqual(model.messageEditSession?.input, value)
    }
    func testCancelReopenAndChangedSourceRejectOldSession() throws {
        let (model, _) = fixture(), value = try input()
        let first = try begin(model)
        XCTAssertTrue(model.updateMessageEditInput(value, sessionID: first.id, contextID: first.contextID))
        XCTAssertTrue(model.cancelMessageEdit(sessionID: first.id, contextID: first.contextID))
        let reopened = try begin(model)
        XCTAssertNotEqual(first.id, reopened.id)
        XCTAssertEqual(reopened.input.formattedText.text, "original")
        XCTAssertFalse(model.cancelMessageEdit(sessionID: first.id, contextID: first.contextID))
        XCTAssertTrue(model.updateMessageEditInput(value, sessionID: reopened.id, contextID: reopened.contextID))
        let replaced = try begin(model, source: source(fingerprint: "v2"))
        XCTAssertNotEqual(reopened.id, replaced.id)
        XCTAssertEqual(replaced.source.fingerprint, "v2")
        XCTAssertEqual(replaced.input.formattedText.text, "original", "A new source version must not inherit the old cached edit")
        XCTAssertFalse(model.updateMessageEditInput(value, sessionID: replaced.id, contextID: UUID()))
    }
    func testSynchronousAckClosesExactSessionAndPreservesOrdinary() throws {
        let (model, provider) = fixture(); provider.synchronous = true; model.draft = "ordinary"
        let session = try begin(model), value = try input()
        XCTAssertTrue(model.updateMessageEditInput(value, sessionID: session.id, contextID: session.contextID))
        XCTAssertTrue(model.performMessageAction(.editFormatted(value.formattedText), source: session.source, contextID: session.contextID))
        XCTAssertNil(model.messageEditSession); XCTAssertEqual(model.draft, "ordinary")
    }
    func testAckWhileAwayRemovesOnlyCapturedChatSession() throws {
        let (model, provider) = fixture()
        let session = try begin(model), value = try input()
        _ = model.updateMessageEditInput(value, sessionID: session.id, contextID: session.contextID)
        XCTAssertTrue(model.performMessageAction(.editFormatted(value.formattedText), source: session.source, contextID: session.contextID))
        model.selectedChatID = 10002
        provider.callback?(.applied)
        model.selectedChatID = 10001
        XCTAssertNil(model.messageEditSession)
    }
    func testSelectionFormatAndReopenedSameTextSurviveOldAck() throws {
        for change in 0..<3 {
            let (model, provider) = fixture()
            let session = try begin(model), value = try input()
            _ = model.updateMessageEditInput(value, sessionID: session.id, contextID: session.contextID)
            XCTAssertTrue(model.performMessageAction(.editFormatted(value.formattedText), source: session.source, contextID: session.contextID))
            if change == 2 {
                model.messageActions.cancel()
                XCTAssertTrue(model.cancelMessageEdit(sessionID: session.id, contextID: session.contextID))
                let replacement = try begin(model)
                XCTAssertTrue(model.updateMessageEditInput(value, sessionID: replacement.id, contextID: replacement.contextID))
            } else {
                let newer = try input(selection: change == 0 ? 2 : 1, bold: change == 0)
                _ = model.updateMessageEditInput(newer, sessionID: session.id, contextID: session.contextID)
            }
            let retained = model.messageEditSession
            provider.callback?(.applied)
            XCTAssertEqual(model.messageEditSession, retained)
        }
    }
    func testEditCancelPreservesOrdinaryReplyAndBeginReplyClosesEdit() throws {
        let (model, _) = fixture()
        model.draft = "ordinary reply draft"
        let message = try XCTUnwrap(model.messages.last(where: { $0.isOutgoing }))
        XCTAssertTrue(model.beginReply(to: message, contextID: model.messageActionContextID))
        let reply = try XCTUnwrap(model.composerReply.resolved)
        let session = try begin(model)
        XCTAssertTrue(model.updateMessageEditInput(try input(), sessionID: session.id, contextID: session.contextID))
        XCTAssertTrue(model.cancelMessageEdit(sessionID: session.id, contextID: session.contextID))
        XCTAssertEqual(model.composerReply.resolved, reply)
        XCTAssertEqual(model.draft, "ordinary reply draft")
        _ = try begin(model)
        XCTAssertTrue(model.beginReply(to: message, contextID: model.messageActionContextID))
        XCTAssertNil(model.messageEditSession)
        XCTAssertEqual(model.composerReply.resolved, reply)
        XCTAssertEqual(model.draft, "ordinary reply draft")
    }
    func testRejectionUncertaintyAndDisconnect() throws {
        for event: TelegramMessageActionEvent in [.rejected, .uncertain] {
            let (model, provider) = fixture()
            let session = try begin(model), value = try input()
            _ = model.updateMessageEditInput(value, sessionID: session.id, contextID: session.contextID)
            XCTAssertTrue(model.performMessageAction(.editFormatted(value.formattedText), source: session.source, contextID: session.contextID))
            provider.callback?(event)
            XCTAssertNotNil(model.messageEditSession)
            model.disconnect()
            provider.callback?(.applied)
            XCTAssertNil(model.messageEditSession)
            XCTAssertEqual(model.messageEditDraft(for: session.source), session.source.text)
            XCTAssertFalse(model.beginMessageEdit(source: session.source, author: "Synthetic", contextID: session.contextID))
        }
    }
}
#endif

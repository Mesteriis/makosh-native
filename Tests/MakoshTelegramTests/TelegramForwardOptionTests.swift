#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramForwardOptionTests: XCTestCase {
    private func fixture() throws -> TelegramModel {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        let source = try XCTUnwrap(model.messages.last.flatMap(model.actionSource))
        XCTAssertTrue(model.stageMessageForward(source: source, destinationChatID: 10002, contextID: model.messageActionContextID))
        model.draft = "ordinary comment 😀"
        return model
    }
    private func change(_ option: TelegramForwardOption, in model: TelegramModel) throws {
        XCTAssertTrue(model.updateForwardOption(option, intentID: try XCTUnwrap(model.composerForwardIntent).id,
            contextID: model.messageActionContextID, expectedChatID: try XCTUnwrap(model.selectedChatID),
            expectedRevision: try XCTUnwrap(model.composerForwardRevision)))
    }

    func testDefaultCaptionHideThenShowRestoresVisibleAuthor() throws {
        let model = try fixture(), original = try XCTUnwrap(model.composerForwardIntent)
        let input = try TelegramComposerInput(formattedText: .init(text: "ordinary comment 😀", entities: [.init(offset: 0, length: 8, kind: .bold)]),
            selection: .init(location: 2, length: 3))
        XCTAssertTrue(model.updateComposerInput(input, contextID: model.messageActionContextID, chatID: 10002))
        XCTAssertTrue(model.beginReply(to: try XCTUnwrap(model.messages.last), contextID: model.messageActionContextID))
        let reply = model.composerReply.resolved
        try change(.captionsHidden(true), in: model)
        XCTAssertEqual(model.composerForwardIntent?.hideNames, true)
        XCTAssertEqual(model.composerForwardIntent?.hideCaptions, true)
        try change(.captionsHidden(false), in: model)
        XCTAssertEqual(model.composerForwardIntent?.hideNames, false)
        XCTAssertEqual(model.composerForwardIntent?.hideCaptions, false)
        XCTAssertEqual(model.composerForwardIntent?.sources, original.sources)
        XCTAssertEqual(model.draft, "ordinary comment 😀")
        XCTAssertEqual(model.composerInput, input)
        XCTAssertEqual(model.composerReply.resolved, reply)
    }

    func testExplicitHiddenAuthorSurvivesCaptionHideAndShow() throws {
        let model = try fixture()
        try change(.authorHidden(true), in: model)
        try change(.captionsHidden(true), in: model)
        try change(.captionsHidden(false), in: model)
        XCTAssertEqual(model.composerForwardIntent?.hideNames, true)
        XCTAssertEqual(model.composerForwardIntent?.hideCaptions, false)
    }

    func testExplicitVisibleAuthorSurvivesCaptionHide() throws {
        let model = try fixture()
        // Choosing the already-visible author must still remember the choice.
        try change(.authorHidden(false), in: model)
        try change(.captionsHidden(true), in: model)
        XCTAssertEqual(model.composerForwardIntent?.hideNames, false)
        XCTAssertEqual(model.composerForwardIntent?.hideCaptions, true)
        try change(.captionsHidden(false), in: model)
        XCTAssertEqual(model.composerForwardIntent?.hideNames, false)
    }

    func testAuthorChoiceAfterCaptionHideControlsLaterCaptionChanges() throws {
        let model = try fixture()
        try change(.captionsHidden(true), in: model)
        try change(.authorHidden(false), in: model)
        try change(.captionsHidden(false), in: model)
        try change(.captionsHidden(true), in: model)
        XCTAssertEqual(model.composerForwardIntent?.hideNames, false)
        XCTAssertEqual(model.composerForwardIntent?.hideCaptions, true)
    }

    func testStaleMenuCannotOverwriteNewerInputOrOptions() throws {
        let model = try fixture(), intent = try XCTUnwrap(model.composerForwardIntent)
        let context = model.messageActionContextID, revision = try XCTUnwrap(model.composerForwardRevision)
        model.draft = "newer comment"
        let current = model.composerForwardRevision
        XCTAssertFalse(model.updateForwardOption(.authorHidden(true), intentID: intent.id, contextID: context,
            expectedChatID: 10002, expectedRevision: revision))
        XCTAssertEqual(model.composerForwardRevision, current)
        XCTAssertEqual(model.composerForwardIntent?.hideNames, false)
        try change(.authorHidden(true), in: model)
        XCTAssertFalse(model.updateForwardOption(.authorHidden(false), intentID: intent.id, contextID: context,
            expectedChatID: 10002, expectedRevision: try XCTUnwrap(current)))
        XCTAssertEqual(model.composerForwardIntent?.hideNames, true)
        XCTAssertEqual(model.draft, "newer comment")
    }

    func testForeignContextChatAndIntentCannotChangeOptions() throws {
        let model = try fixture(), intent = try XCTUnwrap(model.composerForwardIntent)
        let revision = try XCTUnwrap(model.composerForwardRevision), context = model.messageActionContextID
        for (id, token, chat) in [(intent.id, UUID(), Int64(10002)), (intent.id, context, Int64(10003)), (UUID(), context, Int64(10002))] {
            XCTAssertFalse(model.updateForwardOption(.authorHidden(true), intentID: id, contextID: token,
                expectedChatID: chat, expectedRevision: revision))
        }
        XCTAssertEqual(model.composerForwardIntent, intent)
        XCTAssertEqual(model.composerForwardRevision, revision)
    }

    func testExplicitPreferenceSurvivesSerializationAndRecipientChange() throws {
        let model = try fixture()
        try change(.authorHidden(false), in: model)
        try change(.captionsHidden(true), in: model)
        let intent = try XCTUnwrap(model.composerForwardIntent)
        let loaded = try JSONDecoder().decode(TelegramComposerForwardIntent.self, from: JSONEncoder().encode(intent))
        let hiddenAgain = loaded.applying(.captionsHidden(false)).applying(.captionsHidden(true))
        XCTAssertFalse(hiddenAgain.hideNames)
        XCTAssertTrue(hiddenAgain.hideCaptions)
        XCTAssertTrue(model.moveComposerForward(to: 10003, intentID: intent.id, contextID: model.messageActionContextID))
        try change(.captionsHidden(false), in: model)
        try change(.captionsHidden(true), in: model)
        XCTAssertEqual(model.composerForwardIntent?.hideNames, false)
        XCTAssertEqual(model.composerForwardIntent?.hideCaptions, true)
        model.selectedChatID = 10002
        XCTAssertEqual(model.draft, "ordinary comment 😀")
    }

    func testLegacyIntentWithoutPreferenceRetainsFlagsAndUsesDefaultCaptionCoupling() throws {
        let bytes = Data(#"{"id":"00000000-0000-0000-0000-000000000001","sources":[{"chatID":41,"peerID":41,"namespace":0,"messageID":7,"fingerprint":"v1"}],"hideNames":true,"hideCaptions":true}"#.utf8)
        let legacy = try JSONDecoder().decode(TelegramComposerForwardIntent.self, from: bytes)
        XCTAssertTrue(legacy.isValid)
        XCTAssertTrue(legacy.hideNames)
        XCTAssertTrue(legacy.hideCaptions)
        let shown = legacy.applying(.captionsHidden(false))
        XCTAssertFalse(shown.hideNames)
        XCTAssertFalse(shown.hideCaptions)
    }

    func testMalformedOrInconsistentExplicitPreferenceFailsClosed() throws {
        let model = try fixture()
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(model.composerForwardIntent))) as? [String: Any])
        fields["explicitHideNames"] = "unknown"
        XCTAssertThrowsError(try JSONDecoder().decode(TelegramComposerForwardIntent.self, from: JSONSerialization.data(withJSONObject: fields)))
        fields["explicitHideNames"] = true
        let inconsistent = try JSONDecoder().decode(TelegramComposerForwardIntent.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertFalse(inconsistent.isValid)
    }

    func testResolvedPreviewSuppliesAuthorIdentityForDistinctAuthorMenuCount() throws {
        let model = try fixture()
        XCTAssertEqual(model.composerForward.previews.map(\.authorID), [-1])
    }

    func testCaptionChoiceRefusesPlainTextSource() throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        let source = try XCTUnwrap(model.messages.first { $0.actionMetadata?.messageID == 117 }.flatMap(model.actionSource))
        XCTAssertTrue(model.stageMessageForward(source: source, destinationChatID: 10002, contextID: model.messageActionContextID))
        let intent = try XCTUnwrap(model.composerForwardIntent)
        XCTAssertFalse(model.composerForward.previews.contains(where: \.hasCaption))
        XCTAssertFalse(model.updateForwardOption(.captionsHidden(true), intentID: intent.id, contextID: model.messageActionContextID,
            expectedChatID: 10002, expectedRevision: try XCTUnwrap(model.composerForwardRevision)))
        XCTAssertEqual(model.composerForwardIntent, intent)
    }
}
#endif

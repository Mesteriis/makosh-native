import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramUploadReplyMappingTests: XCTestCase {
    func testSelectedQuoteIsRetainedAndCannotBeSubstitutedByAnotherSelection() throws {
        let formatted = try TelegramFormattedText(text: "original")
        let metadata = TelegramMessageActionMetadata(peerID: 2, namespace: Namespaces.Message.Cloud, messageID: 42,
            fingerprint: "version-1", text: "original", authorID: 3, canReply: true, canEdit: false,
            canForward: true, canDeleteLocally: true, canDeleteForEveryone: false, formattedText: formatted, canCopy: true)
        let full = try XCTUnwrap(TelegramReplyQuote(source: formatted, selection: .init(location: 0, length: 8)))
        let partial = try XCTUnwrap(TelegramReplyQuote(source: formatted, selection: .init(location: 0, length: 3)))
        let source = TelegramMessageActionSource(metadata: metadata, accountID: 1, chatID: 2)
        let captured = try XCTUnwrap(source.quoting(full)), changed = try XCTUnwrap(source.quoting(partial))
        let target = TelegramUploadTarget(accountID: 1, chatID: 2, title: "Synthetic", replySource: captured)
        let mapped = try XCTUnwrap(telegramUploadMessage(caption: "", reference: reference(), target: target, replySource: captured))
        guard case let .message(_, _, _, _, _, reply, _, _, _, _) = mapped else { return XCTFail("Expected upload reply") }
        XCTAssertEqual(reply?.quote?.text, "original")
        XCTAssertEqual(reply?.quote?.offset, 0)
        XCTAssertNil(telegramUploadMessage(caption: "", reference: try reference(), target: target, replySource: changed))
    }
    private func source(account: Int64 = 1, chat: Int64 = 2, fingerprint: String = "version-1", canReply: Bool = true) -> TelegramMessageActionSource {
        .init(metadata: .init(peerID: 2, namespace: Namespaces.Message.Cloud, messageID: 42,
            fingerprint: fingerprint, text: "original", authorID: 3, canReply: canReply, canEdit: false,
            canForward: true, canDeleteLocally: true, canDeleteForEveryone: false, threadID: 987),
            accountID: account, chatID: chat)
    }
    private func reference() throws -> AnyMediaReference {
        let file = TelegramUploadFile(id: UUID(), name: "synthetic.txt", size: 3, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: URL(fileURLWithPath: "/synthetic/payload"),
            directory: URL(fileURLWithPath: "/synthetic"))
        return try XCTUnwrap(telegramUploadMedia(file)).1
    }
    func testMediaReplyUsesExactNativeIDThreadAndAllowsEmptyCaption() throws {
        let reply = source(), target = TelegramUploadTarget(accountID: 1, chatID: 2, title: "Fixture", replySource: source())
        let message = try XCTUnwrap(telegramUploadMessage(caption: "", reference: reference(), target: target, replySource: reply))
        guard case let .message(text, _, _, media, thread, subject, _, _, _, _) = message else { return XCTFail("Expected media message") }
        XCTAssertEqual(text, ""); XCTAssertNotNil(media); XCTAssertEqual(thread, 987)
        XCTAssertEqual(subject?.messageId, MessageId(peerId: PeerId(2), namespace: Namespaces.Message.Cloud, id: 42))
        XCTAssertNil(subject?.quote); XCTAssertNil(subject?.todoItemId)
    }
    func testTypedCaptionPreservesNestedUnicodeEntitiesAndNeverFallsBack() throws {
        let target = TelegramUploadTarget(accountID: 1, chatID: 2, title: "Fixture", replySource: source())
        let rich = try TelegramFormattedText(text: "e\u{301} 😀", entities: [
            .init(offset: 0, length: 5, kind: .bold), .init(offset: 3, length: 2, kind: .italic)])
        let message = try XCTUnwrap(telegramUploadMessage(caption: rich, reference: reference(), target: target, replySource: source()))
        guard case let .message(text, attributes, _, _, _, reply, _, _, _, _) = message else { return XCTFail("Expected media") }
        let entities = try XCTUnwrap(attributes.first as? TextEntitiesMessageAttribute)
        XCTAssertEqual(try telegramFormattedText(text: text, entities: entities.entities), rich)
        XCTAssertNotNil(reply)
        XCTAssertNil(telegramUploadMessage(caption: rich, reference: try reference(), target: target, replySource: nil))
        let unsupported = try TelegramFormattedText(text: "x", entities: [.init(offset: 0, length: 1, kind: .customEmoji(stickerPack: nil, fileID: 1))])
        XCTAssertNil(telegramUploadMessage(caption: unsupported, reference: try reference(), target: target, replySource: source()))
    }
    func testMissingStaleOrForeignReplyCannotDegradeToOrdinaryUpload() throws {
        let reference = try reference(), target = TelegramUploadTarget(accountID: 1, chatID: 2, title: "Fixture", replySource: source())
        XCTAssertNil(telegramUploadMessage(caption: "caption", reference: reference, target: target, replySource: nil))
        XCTAssertNil(telegramUploadMessage(caption: "caption", reference: reference, target: target, replySource: source(fingerprint: "edited")))
        XCTAssertNil(telegramUploadMessage(caption: "caption", reference: reference, target: target, replySource: source(account: 9)))
        XCTAssertNil(telegramUploadMessage(caption: "caption", reference: reference, target: target, replySource: source(chat: 9)))
        XCTAssertNil(telegramUploadMessage(caption: "caption", reference: reference, target: target, replySource: source(canReply: false)))
        let invalid = TelegramUploadTarget(accountID: 9, chatID: 2, title: "Other account", replySource: source())
        XCTAssertFalse(invalid.hasValidReplySource)
        XCTAssertNil(telegramUploadMessage(caption: "caption", reference: reference, target: invalid, replySource: source()))
    }
    func testOrdinaryUploadDoesNotAcquireReplyAndCaptionLimitRemainsUTF16() throws {
        let reference = try reference(), target = TelegramUploadTarget(accountID: 1, chatID: 2, title: "Fixture")
        let message = try XCTUnwrap(telegramUploadMessage(caption: "caption", reference: reference, target: target, replySource: nil))
        guard case let .message(_, _, _, _, thread, reply, _, _, _, _) = message else { return XCTFail("Expected message") }
        XCTAssertNil(thread); XCTAssertNil(reply)
        XCTAssertNil(telegramUploadMessage(caption: "caption", reference: reference, target: target, replySource: source()))
        XCTAssertNil(telegramUploadMessage(caption: String(repeating: "😀", count: 513), reference: reference, target: target, replySource: nil))
    }
}

#if DEBUG
@MainActor final class TelegramUploadReplyModelTests: XCTestCase {
    func testPickerCapturesReplyAndCannotRetargetAcrossChatOrAccount() throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        let message = try XCTUnwrap(model.messages.first), source = try XCTUnwrap(model.actionSource(for: message))
        let context = model.uploadContextID
        let target = try XCTUnwrap(model.uploadTarget(replyTo: source, contextID: context))
        XCTAssertEqual(target.replySource, source); XCTAssertEqual(target.chatID, 10001)
        model.selectedChatID = 10002
        XCTAssertNil(model.uploadTarget(replyTo: source, contextID: context))
        XCTAssertEqual(target.replySource, source); XCTAssertEqual(target.chatID, 10001)
        model.disconnect()
        XCTAssertNil(model.uploadTarget(replyTo: source, contextID: context))
    }
    func testInvalidReplyTargetNeverStagesFile() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        let source = try XCTUnwrap(model.actionSource(for: XCTUnwrap(model.messages.first)))
        let foreign = TelegramUploadTarget(accountID: -1, chatID: 10002, title: "Other", replySource: source)
        var staged = false
        model.upload.stage = { _, _ in staged = true; throw TelegramUploadFileError.stagingFailed }
        model.prepareUpload(source: URL(fileURLWithPath: "/synthetic/not-opened"), mode: .file,
            target: foreign, caption: "", contextID: model.uploadContextID)
        await Task.yield()
        XCTAssertFalse(staged); XCTAssertEqual(model.upload.phase, .idle)
    }
    func testSyntheticEditCapabilitiesMatchMediaAndRichFixtures() throws {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        let photo = try XCTUnwrap(model.messages.first { $0.id == "synthetic:10001:130" }.flatMap(model.actionSource))
        XCTAssertEqual(photo.editLimit, 1024); XCTAssertTrue(photo.metadata.allowsEmptyEdit)
        let unsupported = try XCTUnwrap(model.messages.first { $0.id == "synthetic:10001:128" }.flatMap(model.actionSource))
        XCTAssertFalse(unsupported.canEdit)
        let rich = try XCTUnwrap(model.messages.first { $0.id == "synthetic:10001:122" }.flatMap(model.actionSource))
        XCTAssertEqual(rich.metadata.formattedText?.entities.first?.kind, .bold)
    }
}
#endif

import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func emojiFixture(_ id: Int64 = 100, mime: String = "image/webp", premium: Bool = false,
    alt: String = "🦊", singleColor: Bool = false, resourceID: Int64? = nil,
    customAttributes: Bool = true, accessHash: Int64 = 53) -> TelegramMediaFile {
    TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil,
        resource: CloudDocumentMediaResource(datacenterId: 2, fileId: resourceID ?? id, accessHash: accessHash,
            size: 100, fileReference: Data([1, 2]), fileName: "synthetic-emoji.webp"),
        previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: mime, size: 100,
        attributes: customAttributes ? [.CustomEmoji(isPremium: premium, isSingleColor: singleColor,
            alt: alt, packReference: .id(id: 77, accessHash: 79))] : [.FileName(fileName: "not-custom.webp")],
        alternativeRepresentations: [])
}
private nonisolated func emojiUser(_ id: Int64, premium: Bool) -> TelegramUser {
    TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil,
        phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: premium ? [.isPremium] : [],
        emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
        profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func emojiSeed(_ box: Postbox, file: TelegramMediaFile?, premium: Bool?, accountID: Int64 = 1) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        var users = [emojiUser(42, premium: false)]
        if let premium { users.append(emojiUser(accountID, premium: premium)) }
        transaction.updatePeersInternal(users, update: { _, new in new })
        if let file { _ = transaction.updateMedia(file.fileId, update: file); transaction.storeMediaIfNotPresent(media: file) }
        return true
    }
}
private nonisolated func emojiAdmit(_ box: Postbox, text: TelegramFormattedText, registry: TelegramCustomEmojiRegistry,
    accountID: Int64 = 1, targetID: Int64 = 42) -> Signal<Bool, NoError> {
    box.transaction { transaction in telegramCustomEmojiAdmission(formatted: text, registry: registry,
        transaction: transaction, accountPeerID: PeerId(accountID), targetPeerID: PeerId(targetID)) }
}
private nonisolated func emojiQueue(_ box: Postbox, text: TelegramFormattedText, registry: TelegramCustomEmojiRegistry) -> Signal<[MessageId?], NoError> {
    let message = EnqueueMessage.message(text: text.text,
        attributes: [TextEntitiesMessageAttribute(entities: text.engineEntities())], inlineStickers: registry.inlineStickers,
        mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil,
        correlationId: nil, bubbleUpEmojiOrStickersets: [])
    return enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
        peerId: PeerId(42), messages: [message], transactionAdmission: { transaction in
            telegramCustomEmojiAdmission(formatted: text, registry: registry, transaction: transaction,
                accountPeerID: PeerId(1), targetPeerID: PeerId(42))
        })
}
private nonisolated func emojiMessages(_ box: Postbox, ids: [MessageId]) -> Signal<[Message], NoError> {
    box.transaction { transaction in ids.compactMap { transaction.getMessage($0) } }
}

final class TelegramCustomEmojiTests: XCTestCase {
    // Catches trusting filename/MIME alone or dropping the native Premium/template/pack metadata.
    func testDescriptorDerivesExactNativeCustomDocumentMetadata() throws {
        for (mime, format): (String, TelegramCustomEmojiFormat) in [
            ("image/webp", .webP), ("application/x-tgsticker", .tgs), ("video/webm", .webM)] {
            let value = try TelegramCustomEmojiDescriptor(file: emojiFixture(mime: mime, premium: true, singleColor: true))
            XCTAssertEqual(value.fileID, 100); XCTAssertEqual(value.fallbackText, "🦊")
            XCTAssertEqual(value.packReference, .id(id: 77, accessHash: 79)); XCTAssertEqual(value.format, format)
            XCTAssertTrue(value.isPremium); XCTAssertTrue(value.isSingleColor)
        }
    }
    // Catches a cloud document for another ID, an ordinary sticker or malformed fallback gaining insertion authority.
    func testDescriptorRejectsNonCustomMismatchedAndMalformedDocuments() throws {
        for file in [emojiFixture(resourceID: 101), emojiFixture(customAttributes: false),
                     emojiFixture(mime: "text/plain"), emojiFixture(alt: ""), emojiFixture(alt: "ordinary text")] {
            XCTAssertThrowsError(try TelegramCustomEmojiDescriptor(file: file))
        }
    }
    // Catches cached DTO decoding bypassing the same ID/fallback invariants as live descriptors.
    func testDescriptorDecodingRejectsInvalidIDAndFallback() throws {
        let value = try TelegramCustomEmojiDescriptor(file: emojiFixture())
        let bytes = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["fileID"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(TelegramCustomEmojiDescriptor.self, from: JSONSerialization.data(withJSONObject: object)))
        object["fileID"] = 100; object["fallbackText"] = "plain"
        XCTAssertThrowsError(try JSONDecoder().decode(TelegramCustomEmojiDescriptor.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    // Catches UTF16 shifts being computed as Character count or dropping a containing style on insertion.
    func testInsertionReplacesSelectionAndPreservesUTF16Styles() throws {
        let source = try TelegramComposerInput(formattedText: .init(text: "a😀bc", entities: [
            .init(offset: 0, length: 5, kind: .bold), .init(offset: 4, length: 1, kind: .italic)]),
            selection: .init(location: 3, length: 1))
        let result = try TelegramCustomEmojiInsertion.applying(.init(file: emojiFixture()), to: source)
        XCTAssertEqual(result.formattedText.text, "a😀🦊c")
        XCTAssertEqual(result.selection, .init(location: 5, length: 0))
        XCTAssertEqual(result.formattedText.entities, [
            .init(offset: 0, length: 6, kind: .bold), .init(offset: 5, length: 1, kind: .italic),
            .init(offset: 3, length: 2, kind: .customEmoji(stickerPack: .id(id: 77, accessHash: 79), fileID: 100))])
    }
    // Catches an insertion splitting a multi-scalar custom-emoji run and silently changing its document range.
    func testInsertionRejectsPartialCustomEmojiAndPartialSemanticEntities() throws {
        let descriptor = try TelegramCustomEmojiDescriptor(file: emojiFixture())
        let custom = try TelegramComposerInput(formattedText: .init(text: "👨‍👩‍👧", entities: [
            .init(offset: 0, length: 8, kind: .customEmoji(stickerPack: nil, fileID: 99))]),
            selection: .init(location: 2, length: 0))
        XCTAssertThrowsError(try TelegramCustomEmojiInsertion.applying(descriptor, to: custom))
        let link = try TelegramComposerInput(formattedText: .init(text: "hello", entities: [
            .init(offset: 0, length: 5, kind: .textURL(url: "https://example.invalid"))]), selection: .init(location: 1, length: 2))
        XCTAssertThrowsError(try TelegramCustomEmojiInsertion.applying(descriptor, to: link))
    }
    // Catches replacement preserving a removed custom document or altering untouched raw pack provenance.
    func testWholeCustomEmojiReplacementRetainsOtherEntityProvenance() throws {
        let source = try TelegramComposerInput(formattedText: .init(text: "😀 🦊", entities: [
            .init(offset: 0, length: 2, kind: .customEmoji(stickerPack: .name("Synthetic"), fileID: 99)),
            .init(offset: 3, length: 2, kind: .customEmoji(stickerPack: .dice("🎲"), fileID: 98))]), selection: .init(location: 0, length: 2))
        let result = try TelegramCustomEmojiInsertion.applying(.init(file: emojiFixture()), to: source)
        XCTAssertEqual(result.formattedText.text, "🦊 🦊")
        XCTAssertEqual(result.formattedText.entities, [
            .init(offset: 3, length: 2, kind: .customEmoji(stickerPack: .dice("🎲"), fileID: 98)),
            .init(offset: 0, length: 2, kind: .customEmoji(stickerPack: .id(id: 77, accessHash: 79), fileID: 100))])
    }
    // Catches last-writer-wins registry assembly laundering an ordinary/wrong-ID/conflicting native file.
    func testRegistryRejectsConflictingNativeRecords() throws {
        XCTAssertThrowsError(try TelegramCustomEmojiRegistry(accountID: 1, files: [emojiFixture(), emojiFixture(premium: true)]))
        XCTAssertThrowsError(try TelegramCustomEmojiRegistry(accountID: 1, files: [emojiFixture(customAttributes: false)]))
        XCTAssertThrowsError(try TelegramCustomEmojiRegistry(accountID: 1, files: [emojiFixture(resourceID: 101)]))
        XCTAssertNoThrow(try TelegramCustomEmojiRegistry(accountID: 1, files: [emojiFixture(), emojiFixture()]))
    }
}

@MainActor final class TelegramCustomEmojiNativeTests: TelegramSourceFactsIntegrationTestCase {
    private func box() async throws -> Postbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try await sourceFactsOpen(root.appendingPathComponent("postbox"))
    }
    private func text(_ fileID: Int64 = 100) throws -> TelegramFormattedText {
        try .init(text: "🦊", entities: [.init(offset: 0, length: 2, kind: .customEmoji(stickerPack: .name("Retained provenance"), fileID: fileID))])
    }
    // Catches Premium treated as mandatory for free emoji or the reference Saved Messages exception being lost.
    func testNativeAdmissionUsesCurrentAccountTierAndSavedMessagesException() async throws {
        let box = try await box(), free = emojiFixture(), paid = emojiFixture(101, premium: true)
        _ = try await sourceFactsValue(emojiSeed(box, file: free, premium: false))
        _ = try await sourceFactsValue(emojiSeed(box, file: paid, premium: false))
        let freeRegistry = try TelegramCustomEmojiRegistry(accountID: 1, files: [free])
        let paidRegistry = try TelegramCustomEmojiRegistry(accountID: 1, files: [paid])
        let freeAllowed = try await sourceFactsValue(emojiAdmit(box, text: text(), registry: freeRegistry))
        let paidDenied = try await sourceFactsValue(emojiAdmit(box, text: text(101), registry: paidRegistry))
        let savedAllowed = try await sourceFactsValue(emojiAdmit(box, text: text(101), registry: paidRegistry, targetID: 1))
        XCTAssertTrue(freeAllowed); XCTAssertFalse(paidDenied); XCTAssertTrue(savedAllowed)
        _ = try await sourceFactsValue(emojiSeed(box, file: nil, premium: true))
        let paidAllowed = try await sourceFactsValue(emojiAdmit(box, text: text(101), registry: paidRegistry))
        XCTAssertTrue(paidAllowed)
        _ = try await sourceFactsValue(emojiSeed(box, file: nil, premium: false))
        let downgraded = try await sourceFactsValue(emojiAdmit(box, text: text(101), registry: paidRegistry))
        XCTAssertFalse(downgraded)
    }
    // Catches an in-memory descriptor or another account's registry authorizing a missing/stale native cloud record.
    func testNativeAdmissionRejectsUnknownAccountMissingCoverageAndChangedCachedFile() async throws {
        let box = try await box(), file = emojiFixture()
        let registry = try TelegramCustomEmojiRegistry(accountID: 1, files: [file])
        _ = try await sourceFactsValue(emojiSeed(box, file: file, premium: nil))
        let unknownUser = try await sourceFactsValue(emojiAdmit(box, text: text(), registry: registry))
        XCTAssertFalse(unknownUser)
        _ = try await sourceFactsValue(emojiSeed(box, file: file, premium: true))
        let wrongAccount = try await sourceFactsValue(emojiAdmit(box, text: text(), registry: registry, accountID: 42))
        let missingCoverage = try await sourceFactsValue(emojiAdmit(box, text: text(101), registry: registry))
        XCTAssertFalse(wrongAccount); XCTAssertFalse(missingCoverage)
        _ = try await sourceFactsValue(emojiSeed(box, file: emojiFixture(accessHash: 999), premium: true))
        let stale = try await sourceFactsValue(emojiAdmit(box, text: text(), registry: registry))
        XCTAssertFalse(stale)
    }
    // Catches a retained custom range hiding only one scalar of a larger ZWJ
    // grapheme, which would disagree with the Unicode preserved in the editor.
    func testNativeAdmissionRejectsPartialSourceEmojiGrapheme() async throws {
        let box = try await box(), file = emojiFixture()
        let registry = try TelegramCustomEmojiRegistry(accountID: 1, files: [file])
        _ = try await sourceFactsValue(emojiSeed(box, file: file, premium: true))
        let partial = try TelegramFormattedText(text: "👨‍👩‍👧", entities: [
            .init(offset: 0, length: 2, kind: .customEmoji(stickerPack: nil, fileID: 100))])
        let whole = try TelegramFormattedText(text: "👨‍👩‍👧", entities: [
            .init(offset: 0, length: 8, kind: .customEmoji(stickerPack: .name("Retained pack"), fileID: 100))])
        let denied = try await sourceFactsValue(emojiAdmit(box, text: partial, registry: registry))
        let accepted = try await sourceFactsValue(emojiAdmit(box, text: whole, registry: registry))
        XCTAssertFalse(denied); XCTAssertTrue(accepted)
    }
    // Catches an admission check that never reaches the real native queue or drops its associated cloud document/ranges.
    func testNativeQueueStoresResolvedCustomEmojiAndRejectsDowngradeInEnqueueTransaction() async throws {
        let box = try await box(), file = emojiFixture(premium: true)
        let registry = try TelegramCustomEmojiRegistry(accountID: 1, files: [file]), formatted = try text()
        _ = try await sourceFactsValue(emojiSeed(box, file: file, premium: true))
        let accepted = try await sourceFactsValue(emojiQueue(box, text: formatted, registry: registry))
        XCTAssertEqual(accepted.compactMap { $0 }.count, 1)
        let messages = try await sourceFactsValue(emojiMessages(box, ids: accepted.compactMap { $0 }))
        guard let message = messages.first else { XCTFail("Resolved custom emoji must reach native local queue"); return }
        XCTAssertEqual(message.text, "🦊")
        XCTAssertEqual(message.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities,
            [MessageTextEntity(range: 0..<2, type: .CustomEmoji(stickerPack: .name("Retained provenance"), fileId: 100))])
        XCTAssertTrue((message.associatedMedia[file.fileId] as? TelegramMediaFile)?.isEqual(to: file) == true)
        _ = try await sourceFactsValue(emojiSeed(box, file: nil, premium: false))
        let denied = try await sourceFactsValue(emojiQueue(box, text: formatted, registry: registry))
        XCTAssertTrue(denied.isEmpty)
    }
}

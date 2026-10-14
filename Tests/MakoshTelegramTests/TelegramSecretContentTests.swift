import XCTest
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func contentUser(_ number: Int64) -> TelegramUser {
    .init(id: PeerId(number), accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func contentFile(size: Int64 = 128, cover: TelegramMediaImage? = nil, attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: "synthetic.txt")]) -> TelegramMediaFile {
    .init(fileId: .init(namespace: Namespaces.Media.LocalFile, id: 10), partialReference: nil,
        resource: LocalFileMediaResource(fileId: 10, size: size), previewRepresentations: [], videoThumbnails: [], videoCover: cover,
        immediateThumbnailData: nil, mimeType: "application/octet-stream", size: size, attributes: attributes, alternativeRepresentations: [])
}
private nonisolated func contentPhoto() -> TelegramMediaImage {
    .init(imageId: .init(namespace: Namespaces.Media.LocalImage, id: 20), representations: [
        .init(dimensions: .init(width: 640, height: 480), resource: LocalFileMediaResource(fileId: 20, size: 100), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
    ], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
}
private nonisolated func contentMessage(text: String = "Test", entities: [MessageTextEntity] = [], media: Media? = nil,
    reply: EngineMessageReplySubject? = nil, grouping: Int64? = nil, attributes: [MessageAttribute] = []) -> EnqueueMessage {
    .message(text: text, attributes: attributes + (entities.isEmpty ? [] : [TextEntitiesMessageAttribute(entities: entities)]),
        inlineStickers: [:], mediaReference: media.map { .standalone(media: $0) }, threadId: nil, replyToMessageId: reply,
        replyToStoryId: nil, localGroupingKey: grouping, correlationId: nil, bubbleUpEmojiOrStickersets: [])
}
private nonisolated func contentFixture(_ box: Postbox, layer: SecretChatLayer, messages: [EnqueueMessage], globalID: Int64? = 77,
    replyProbe: Bool = false) -> Signal<([Bool], Bool, Bool), NoError> {
    box.transaction { transaction in
        let own = contentUser(101), regular = contentUser(42)
        let id = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(-44))
        let peer = TelegramSecretChat(id: id, creationDate: 100, regularPeerId: regular.id, accessHash: 88, role: .creator, embeddedState: .active, messageAutoremoveTimeout: nil)
        let sequence = SecretChatSequenceBasedLayerState(layerNegotiationState: .init(activeLayer: SecretChatSequenceBasedLayer(rawValue: layer.rawValue) ?? .layer144, locallyRequestedLayer: layer.rawValue, remotelyRequestedLayer: layer.rawValue),
            rekeyState: nil, baseIncomingOperationIndex: 0, baseOutgoingOperationIndex: 0, topProcessedCanonicalIncomingOperationIndex: nil)
        let state = SecretChatState(role: .creator, embeddedState: layer == .layer8 ? .basicLayer : .sequenceBasedLayer(sequence),
            keychain: .init(keys: [.init(fingerprint: 1, key: .init(data: Data(repeating: 0x5a, count: 256)), validity: .indefinite, useCount: 0)]),
            keyFingerprint: .init(sha1: .init(digest: Data(0..<20)), sha256: .init(digest: Data(32..<64))), messageAutoremoveTimeout: nil)
        transaction.updatePeersInternal([own, regular, peer], update: { _, value in value }); transaction.setPeerChatState(id, state: state)
        let sourceID = MessageId(peerId: id, namespace: Namespaces.Message.SecretIncoming, id: 1)
        transaction.deleteMessages([sourceID], forEachMedia: nil)
        _ = transaction.addMessages([StoreMessage(id: sourceID, globallyUniqueId: globalID, groupingKey: nil, threadId: nil,
            timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: regular.id,
            text: "Synthetic source", attributes: [], media: [])], location: .Random)
        let context = TelegramSendContext(accountID: 101, chatID: id.toInt64(), threadID: nil, submissionRevision: UUID(), messageCount: 1)
        let results = messages.map { telegramSendAuthorization(transaction: transaction, context: context, messages: [$0]) }
        guard replyProbe, let source = transaction.getMessage(sourceID), let formatted = try? TelegramFormattedText(text: "Reply") else { return (results, false, false) }
        let metadata = telegramMessageActionSource(source, accountID: 101, chatID: id.toInt64())
        let reply = telegramReplyEnqueueMessage(transaction: transaction, accountID: 101, source: metadata, formatted: formatted)
        return (results, metadata.canReply, reply != nil && telegramSendAuthorization(transaction: transaction, context: context, messages: [reply!]))
    }
}
private nonisolated func contentVoicePermission(_ box: Postbox, allowed: Bool, kind: TelegramRecordingKind) -> Signal<TelegramVoiceEligibility, NoError> {
    box.transaction { transaction in
        transaction.updatePeerCachedData(peerIds: [PeerId(42)], update: { _, _ in CachedUserData().withUpdatedVoiceMessagesAvailable(allowed) })
        let id = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(-44))
        return telegramVoiceEligibilitySnapshot(transaction: transaction, peerID: id, now: 1000, kind: kind)
    }
}
private nonisolated func contentRetainedRemoval(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let peer = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(-44))
        let id = MessageId(peerId: peer, namespace: Namespaces.Message.SecretIncoming, id: 2)
        let media = contentFile()
        let message = StoreMessage(id: id, globallyUniqueId: 89, groupingKey: nil, threadId: nil, timestamp: 100,
            flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: PeerId(42),
            text: "Retained secret text", attributes: [AutoremoveTimeoutMessageAttribute(timeout: 60, countdownBeginTime: 100)], media: [media])
        _ = transaction.addMessages([message], location: .Random)
        transaction.deleteMessages([id], forEachMedia: nil)
        guard transaction.getMessage(id) == nil, let events = try? transaction.makoshArchiveJournal(limit: 1000) else { return false }
        let versions = events.filter { $0.id == id }
        guard versions.contains(where: { !$0.removed }), let removed = versions.last, removed.removed else { return false }
        return removed.text == "Retained secret text" && (removed.attributes.first as? AutoremoveTimeoutMessageAttribute)?.timeout == 60
            && (removed.media.first as? TelegramMediaFile)?.resource.id == media.resource.id
    }
}
@MainActor final class TelegramSecretContentTests: XCTestCase {
    func testSecretRecordingRequiresNegotiatedLayerAndCurrentParticipantPrivacy() async throws {
        let box = try await telegramDataPostbox(test: self)
        _ = try await telegramDataValue(contentFixture(box, layer: .layer144, messages: []), test: self)
        let voice = try await telegramDataValue(contentVoicePermission(box, allowed: true, kind: .voice), test: self)
        let round = try await telegramDataValue(contentVoicePermission(box, allowed: true, kind: .roundVideo), test: self)
        let denied = try await telegramDataValue(contentVoicePermission(box, allowed: false, kind: .voice), test: self)
        XCTAssertEqual(voice, .allowed); XCTAssertEqual(round, .allowed); XCTAssertEqual(denied, .voicePrivacy)
        _ = try await telegramDataValue(contentFixture(box, layer: .layer8, messages: []), test: self)
        let basic = try await telegramDataValue(contentVoicePermission(box, allowed: true, kind: .voice), test: self)
        XCTAssertEqual(basic, .restricted)
    }
    func testNativeTTLOrRemoteRemovalRetainsSecretTextAttributesAndResourceReferences() async throws {
        let box = try await telegramDataPostbox(test: self)
        let retained = try await telegramDataValue(contentRetainedRemoval(box), test: self)
        XCTAssertTrue(retained)
    }
    func testFormattingIsAdmittedOnlyWhenNativeLayerPreservesIt() async throws {
        let box = try await telegramDataPostbox(test: self)
        let messages = [contentMessage(entities: [.init(range: 0..<4, type: .Bold)]), contentMessage(entities: [.init(range: 0..<4, type: .Underline)]),
            contentMessage(entities: [.init(range: 0..<4, type: .Spoiler)]), contentMessage(entities: [.init(range: 0..<4, type: .Pre(language: "swift"))])]
        let old = try await telegramDataValue(contentFixture(box, layer: .layer73, messages: messages), test: self)
        XCTAssertEqual(old.0, [true, false, false, false])
        let modern = try await telegramDataValue(contentFixture(box, layer: .layer144, messages: messages), test: self)
        XCTAssertEqual(modern.0, [true, true, true, false])
    }
    func testPreparedLocalPhotosFilesAndAlbumsRequireSupportedNativeSizesAndLayer() async throws {
        let box = try await telegramDataPostbox(test: self)
        let messages = [contentMessage(text: "", media: contentFile()), contentMessage(media: contentPhoto(), grouping: 9),
            contentMessage(media: contentFile(size: Int64(Int32.max) + 1)), contentMessage(media: contentFile(cover: contentPhoto())),
            contentMessage(media: contentPhoto(), attributes: [InvertMediaMessageAttribute()])]
        let older = try await telegramDataValue(contentFixture(box, layer: .layer46, messages: messages), test: self)
        XCTAssertEqual(older.0, [true, false, false, false, false])
        let modern = try await telegramDataValue(contentFixture(box, layer: .layer144, messages: messages), test: self)
        XCTAssertEqual(modern.0, [true, true, true, false, false])
    }
    func testRepliesRequireSameSecretNativeSourceAndGlobalID() async throws {
        let box = try await telegramDataPostbox(test: self)
        let good = try await telegramDataValue(contentFixture(box, layer: .layer144, messages: [], replyProbe: true), test: self)
        XCTAssertTrue(good.1); XCTAssertTrue(good.2)
        let missing = try await telegramDataValue(contentFixture(box, layer: .layer144, messages: [], globalID: nil, replyProbe: true), test: self)
        XCTAssertFalse(missing.1); XCTAssertFalse(missing.2)
    }
    func testEncryptedRepliesCannotPointAtForeignChatsOrCarryCloudQuotes() async throws {
        let box = try await telegramDataPostbox(test: self)
        let id = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(-44))
        let source = MessageId(peerId: id, namespace: Namespaces.Message.SecretIncoming, id: 1)
        let values = [contentMessage(reply: .init(messageId: source, quote: nil, todoItemId: nil)),
            contentMessage(reply: .init(messageId: .init(peerId: PeerId(42), namespace: Namespaces.Message.Cloud, id: 1), quote: nil, todoItemId: nil)),
            contentMessage(reply: .init(messageId: source, quote: .init(text: "Source", offset: 0, entities: [], media: nil), todoItemId: nil))]
        let modern = try await telegramDataValue(contentFixture(box, layer: .layer144, messages: values), test: self)
        XCTAssertEqual(modern.0, [true, false, false])
        let basic = try await telegramDataValue(contentFixture(box, layer: .layer8, messages: values), test: self)
        XCTAssertEqual(basic.0, [false, false, false])
    }
}

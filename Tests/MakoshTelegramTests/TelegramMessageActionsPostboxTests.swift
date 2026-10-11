import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func actionPeer(_ id: PeerId, accessHash: TelegramPeerAccessHash? = nil) -> TelegramUser {
    TelegramUser(id: id,accessHash: accessHash,firstName: "Synthetic",lastName: nil,username: nil,phone: nil,
        photo: [],botInfo: nil,restrictionInfo: nil,flags: [],emojiStatus: nil,usernames: [],storiesHidden: nil,
        nameColor: nil,backgroundEmojiId: nil,profileColor: nil,profileBackgroundEmojiId: nil,
        subscriberCount: nil,verificationIconFileId: nil)
}
private func actionFixture(_ box: Postbox, peer: PeerId, text: String, flags: StoreMessageFlags = [], update: Bool = false, media: [Media] = []) -> Signal<Message?, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([actionPeer(peer)],update: { _,new in new })
        let id = MessageId(peerId: peer,namespace: Namespaces.Message.Cloud,id: 1)
        let message = StoreMessage(id: id,globallyUniqueId: nil,groupingKey: nil,threadId: nil,
            timestamp: Int32(Date().timeIntervalSince1970) - 1,flags: flags,tags: [],globalTags: [],
            localTags: [],forwardInfo: nil,authorId: peer,text: text,attributes: [],media: media)
        if update { transaction.updateMessage(id) { _ in .update(message) } }
        else { _ = transaction.addMessages([message],location: .Random) }
        return transaction.getMessage(id)
    }
}
// Read after the preceding write commits: production history observes committed peers/version.
private func actionCommittedMessage(_ box: Postbox, peer: PeerId) -> Signal<Message?, NoError> {
    box.transaction { transaction in
        transaction.getMessage(MessageId(peerId: peer,namespace: Namespaces.Message.Cloud,id: 1))
    }
}
// These closures run on Postbox's queue, outside the test's MainActor.
private func actionMentionPeer(_ box: Postbox, peer: PeerId, hash: TelegramPeerAccessHash?) -> Signal<Void, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([actionPeer(peer, accessHash: hash)], update: { _, new in new })
    }
}
private func actionDeleteAndJournal(_ box: Postbox, id: MessageId) -> Signal<Result<[MakoshMessageJournalEntry], Error>, NoError> {
    box.transaction { transaction in
        transaction.deleteMessages([id],forEachMedia: nil)
        return Result { try transaction.makoshArchiveJournal(limit: 100) }
    }
}

@MainActor final class TelegramMessageActionsPostboxTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Synthetic Postbox result")
        var result: T?
        let disposable = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { disposable.dispose() }
        await fulfillment(of: [done],timeout: 20)
        return try XCTUnwrap(result)
    }
    func testFreshTransactionValidationRejectsStaleAndDeletedSourcesWithoutLosingJournal() async throws {
        initializeAccountManagement()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 3,count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 4,count: 16)))
        let opened = expectation(description: "Synthetic encrypted Postbox")
        var box: Postbox?
        let opening = (openPostbox(basePath: directory.path,seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true,key: key,salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1,isMainProcess: true,isTemporary: false,isReadOnly: false,
            useCopy: false,useCaches: false,removeDatabaseOnError: false) |> deliverOnMainQueue).start(next: {
                if case let .postbox(value) = $0 { box = value; opened.fulfill() }
            })
        defer { opening.dispose() }
        await fulfillment(of: [opened],timeout: 20)
        let postbox = try XCTUnwrap(box)
        // MediaBox opens these databases on a separate shared queue. Postbox
        // transactions alone do not finish their initialization before teardown.
        _ = try await value(postbox.mediaBox.storageBox.all())
        _ = try await value(postbox.mediaBox.cacheStorageBox.all())
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser,id: ._internalFromInt64Value(77))
        _ = try await value(actionFixture(postbox,peer: peer,text: "original"))
        let firstResult = try await value(actionCommittedMessage(postbox,peer: peer))
        let first = try XCTUnwrap(firstResult)
        XCTAssertTrue(first.peers[peer] is TelegramUser)
        XCTAssertTrue(first.author is TelegramUser)
        let account = peer.toInt64()
        let source = telegramMessageActionSource(first,accountID: account,chatID: account)
        let mentionedPeer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(88))
        let formattedReply = try TelegramFormattedText(text: "Mention", entities: [
            .init(offset: 0, length: 7, kind: .textMention(peerID: mentionedPeer.toInt64()))
        ])
        let missingMention = try await value(telegramValidateOutgoingText(postbox: postbox, formatted: formattedReply))
        XCTAssertFalse(missingMention)
        let missingMentionReply = try await value(validateTelegramMessageAction(postbox: postbox, accountID: account,
            action: .replyFormatted(formattedReply), source: source))
        XCTAssertFalse(missingMentionReply)
        _ = try await value(actionMentionPeer(postbox, peer: mentionedPeer, hash: nil))
        let hashlessMention = try await value(telegramValidateOutgoingText(postbox: postbox, formatted: formattedReply))
        XCTAssertFalse(hashlessMention)
        _ = try await value(actionMentionPeer(postbox, peer: mentionedPeer, hash: .personal(123)))
        let validMention = try await value(telegramValidateOutgoingText(postbox: postbox, formatted: formattedReply))
        XCTAssertTrue(validMention)
        let validMentionReply = try await value(validateTelegramMessageAction(postbox: postbox, accountID: account,
            action: .replyFormatted(formattedReply), source: source))
        XCTAssertTrue(validMentionReply)
        let fresh = try await value(validateTelegramMessageAction(postbox: postbox,accountID: account,action: .edit("edited"),source: source))
        XCTAssertTrue(fresh)
        let reply = try await value(validateTelegramReplySource(postbox: postbox,accountID: account,source: source))
        XCTAssertEqual(reply?.fingerprint,source.fingerprint)
        let foreignReply = try await value(validateTelegramReplySource(postbox: postbox,accountID: account + 1,source: source))
        XCTAssertNil(foreignReply)
        let wrongAccount = try await value(validateTelegramMessageAction(postbox: postbox,accountID: account + 1,action: .reply("x"),source: source))
        XCTAssertFalse(wrongAccount)
        let wrongChat = TelegramMessageActionSource(metadata: source.metadata,accountID: account,chatID: account + 1)
        let wrong = try await value(validateTelegramMessageAction(postbox: postbox,accountID: account,action: .reply("x"),source: wrongChat))
        XCTAssertFalse(wrong)
        let missingDestination = try await value(validateTelegramMessageAction(postbox: postbox,accountID: account,action: .forward(destinationChatID: account + 99),source: source))
        XCTAssertFalse(missingDestination)
        let photo = TelegramMediaImage(imageId: MediaId(namespace: 0,id: 77),representations: [],
            immediateThumbnailData: nil,reference: nil,partialReference: nil,flags: [])
        _ = try await value(actionFixture(postbox,peer: peer,text: "",update: true,media: [photo]))
        let emptyResult = try await value(actionCommittedMessage(postbox,peer: peer))
        let empty = try XCTUnwrap(emptyResult)
        let emptySource = telegramMessageActionSource(empty,accountID: account,chatID: account)
        let emptyReply = try await value(validateTelegramReplySource(postbox: postbox,accountID: account,source: emptySource))
        XCTAssertNotNil(emptyReply); XCTAssertEqual(emptyReply?.text, "")
        let staleReply = try await value(validateTelegramReplySource(postbox: postbox,accountID: account,source: source))
        XCTAssertNil(staleReply)


        _ = try await value(actionFixture(postbox,peer: peer,text: "edited",update: true))
        let editedResult = try await value(actionCommittedMessage(postbox,peer: peer))
        let edited = try XCTUnwrap(editedResult)
        let stale = try await value(validateTelegramMessageAction(postbox: postbox,accountID: account,action: .reply("x"),source: source))
        XCTAssertFalse(stale)
        _ = try await value(actionFixture(postbox,peer: peer,text: "edited",flags: [.CopyProtected],update: true))
        let protectedResult = try await value(actionCommittedMessage(postbox,peer: peer))
        let protected = try XCTUnwrap(protectedResult)
        let protectedSource = telegramMessageActionSource(protected,accountID: account,chatID: account)
        let denied = try await value(validateTelegramMessageAction(postbox: postbox,accountID: account,action: .forward(destinationChatID: account),source: protectedSource))
        XCTAssertFalse(denied)
        let journal = try await value(actionDeleteAndJournal(postbox,id: edited.id)).get()
        XCTAssertTrue(journal.contains { $0.text == "original" && !$0.removed })
        XCTAssertTrue(journal.contains { $0.text == "edited" && !$0.removed })
        XCTAssertTrue(journal.contains { $0.id == edited.id && $0.removed })
        let deleted = try await value(validateTelegramMessageAction(postbox: postbox,accountID: account,action: .reply("x"),source: protectedSource))
        XCTAssertFalse(deleted)
        let removedReply = try await value(validateTelegramReplySource(postbox: postbox,accountID: account,source: protectedSource))
        XCTAssertNil(removedReply)

        _ = try await value(actionFixture(postbox,peer: peer,text: "incoming",flags: [.Incoming]))
        let incomingResult = try await value(actionCommittedMessage(postbox,peer: peer))
        let incoming = try XCTUnwrap(incomingResult)
        let incomingSource = telegramMessageActionSource(incoming,accountID: account + 1,chatID: account)
        XCTAssertTrue(incomingSource.canDeleteForEveryone) // Candidate without server configuration.
        let defaultDenied = try await value(validateTelegramMessageAction(postbox: postbox,accountID: account + 1,action: .delete(forEveryone: true),source: incomingSource))
        XCTAssertFalse(defaultDenied) // Fresh default configuration is authoritative.
    }
}

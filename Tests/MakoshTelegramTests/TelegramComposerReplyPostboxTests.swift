import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func composerFixtureRaw(_ box: Postbox, chatID: Int64, data: Data?) -> Signal<Data?, NoError> {
    box.transaction { transaction in
        let key = PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(chatID))
        if let data { transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: data)) }
        return transaction.getPreferencesEntry(key: key)?.data
    }
}

private func replyFixturePeer(_ id: PeerId) -> TelegramUser {
    TelegramUser(id: id,accessHash: nil,firstName: "Synthetic",lastName: nil,username: nil,phone: nil,
        photo: [],botInfo: nil,restrictionInfo: nil,flags: [],emojiStatus: nil,usernames: [],storiesHidden: nil,
        nameColor: nil,backgroundEmojiId: nil,profileColor: nil,profileBackgroundEmojiId: nil,
        subscriberCount: nil,verificationIconFileId: nil)
}
private func replyFixtureMessage(_ box: Postbox, peer: PeerId, text: String, flags: StoreMessageFlags = [], update: Bool = false, media: [Media] = []) -> Signal<Message?, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([replyFixturePeer(peer)],update: { _,new in new })
        let id = MessageId(peerId: peer,namespace: Namespaces.Message.Cloud,id: 1)
        let message = StoreMessage(id: id,globallyUniqueId: nil,groupingKey: nil,threadId: nil,
            timestamp: Int32(Date().timeIntervalSince1970) - 1,flags: flags,tags: [],globalTags: [],
            localTags: [],forwardInfo: nil,authorId: peer,text: text,attributes: [],media: media)
        if update { transaction.updateMessage(id) { _ in .update(message) } }
        else { _ = transaction.addMessages([message],location: .Random) }
        return transaction.getMessage(id)
    }
}
private func removeReplyFixture(_ box: Postbox, peer: PeerId) -> Signal<Void, NoError> {
    box.transaction { $0.deleteMessages([MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1)], forEachMedia: nil) }
}

@MainActor final class TelegramComposerReplyPostboxTests: XCTestCase {
    private weak var previousBox: Postbox?
    private func open(_ root: URL) async throws -> Postbox {
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Encrypted draft fixture")
        var box: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(value) = $0 { box = value; opened.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let result = try XCTUnwrap(box)
        let ready = expectation(description: "Both MediaBox stores ready"); ready.expectedFulfillmentCount = 2
        let storage = (result.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        let cache = (result.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        defer { storage.dispose(); cache.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return result
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func save(_ draft: TelegramComposerDraft, to repository: TelegramPostboxComposerDraftRepository) async -> Result<Void, TelegramComposerDraftPersistenceError> {
        let done = expectation(description: "Draft transaction completed")
        var result: Result<Void, TelegramComposerDraftPersistenceError> = .failure(.unavailable)
        repository.save(draft) { result = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 20)
        return result
    }
    private func load(_ chat: Int64, from repository: TelegramPostboxComposerDraftRepository) async -> Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError> {
        let done = expectation(description: "Draft loaded")
        var result: Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError> = .failure(.unavailable)
        let read = repository.load(chatID: chat) { result = $0; done.fulfill() }
        defer { read.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return result
    }
    private func raw(_ box: Postbox, chat: Int64, data: Data? = nil) async -> Data? {
        let done = expectation(description: "Raw fixture preference transaction")
        var result: Data?
        let op = (composerFixtureRaw(box, chatID: chat, data: data) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { op.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return result
    }
    private func seedThenRelease(_ path: URL, draft: TelegramComposerDraft) async throws {
        let box = try await open(path)
        previousBox = box
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: draft.accountID)
        try await save(draft, to: repository).get()
        let loaded = try await load(draft.chatID, from: repository).get()
        XCTAssertEqual(loaded, draft)
    }

    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Committed reply lookup")
        var result: T?
        let operation = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { operation.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func seedReplyThenRelease(_ path: URL, draft: TelegramComposerDraft, peer: PeerId) async throws {
        let box = try await open(path)
        previousBox = box
        _ = try await value(replyFixtureMessage(box, peer: peer, text: "original"))
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: draft.accountID)
        try await save(draft, to: repository).get()
    }
    func testDurableTargetResolvesFreshCommittedMessageAfterEncryptedReopen() async throws {
        let path = try root()
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77))
        let chat = peer.toInt64()
        let target = TelegramComposerReplyTarget(peerID: chat, namespace: Namespaces.Message.Cloud, messageID: 1)
        let draft = TelegramComposerDraft(accountID: 99, chatID: chat, text: "reply draft", replyTarget: target)
        try await seedReplyThenRelease(path, draft: draft, peer: peer)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let box = try await open(path)
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 99)
        let restored = try await load(chat, from: repository).get()
        XCTAssertEqual(restored, draft)
        let durableTarget = try XCTUnwrap(restored?.replyTarget)
        let firstResult = try await value(telegramComposerReply(postbox: box, accountID: 99, target: durableTarget, chatID: chat))
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.source.text, "original")
        XCTAssertEqual(first.source.accountID, 99)
        XCTAssertEqual(first.author, "Synthetic")
        XCTAssertTrue(first.source.canReply)
        _ = try await value(replyFixtureMessage(box, peer: peer, text: "edited", update: true))
        let editedResult = try await value(telegramComposerReply(postbox: box, accountID: 99, target: durableTarget, chatID: chat))
        let edited = try XCTUnwrap(editedResult)
        XCTAssertEqual(edited.source.text, "edited")
        XCTAssertNotEqual(edited.source.fingerprint, first.source.fingerprint)
        for invalid in [
            TelegramComposerReplyTarget(peerID: chat, namespace: Namespaces.Message.Cloud + 1, messageID: 1),
            TelegramComposerReplyTarget(peerID: chat, namespace: Namespaces.Message.Cloud, messageID: 999),
            TelegramComposerReplyTarget(peerID: chat, namespace: Namespaces.Message.Cloud, messageID: 0),
            TelegramComposerReplyTarget(peerID: chat, namespace: Namespaces.Message.Cloud, messageID: 1, threadID: 9)
        ] {
            let missing = try await value(telegramComposerReply(postbox: box, accountID: 99, target: invalid, chatID: chat))
            XCTAssertNil(missing)
        }
        let foreign = try await value(telegramComposerReply(postbox: box, accountID: 99, target: durableTarget, chatID: chat + 1))
        XCTAssertNil(foreign)
        _ = try await value(removeReplyFixture(box, peer: peer))
        let removed = try await value(telegramComposerReply(postbox: box, accountID: 99, target: durableTarget, chatID: chat))
        XCTAssertNil(removed)
        let retainedDraft = try await load(chat, from: repository).get()
        XCTAssertEqual(retainedDraft, draft, "Missing cached source does not erase the durable composer target")
    }
}

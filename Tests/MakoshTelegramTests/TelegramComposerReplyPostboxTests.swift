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
        transaction.updatePeersInternal([replyFixturePeer(peer), replyFixturePeer(PeerId(99))],update: { _,new in new })
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

private func quoteReplyMessage(_ box: Postbox, source: TelegramMessageActionSource, text: TelegramFormattedText) -> Signal<EnqueueMessage?, NoError> {
    box.transaction { telegramReplyEnqueueMessage(transaction: $0, accountID: 99, source: source, formatted: text) }
}
private func quoteReplyQueue(_ box: Postbox, source: TelegramMessageActionSource, text: TelegramFormattedText, message: EnqueueMessage) -> Signal<[MessageId?], NoError> {
    enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(99), isSupportUser: false, timestamp: 200,
        peerId: PeerId(source.chatID), messages: [message], transactionAdmission: {
            telegramReplyEnqueueMessage(transaction: $0, accountID: 99, source: source, formatted: text) != nil
        })
}
private func quoteReplyRead(_ box: Postbox, id: MessageId) -> Signal<Message?, NoError> {
    box.transaction { $0.getMessage(id) }
}

private nonisolated func singleQuoteSeed(_ box: Postbox, draft: TelegramPendingUploadDraft, limit: Int) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        var config = AppConfiguration.defaultValue
        config.data = .dictionary(["quote_length_max": .number(Double(limit))])
        transaction.setPreferencesEntry(key: PreferencesKeys.appConfiguration, value: PreferencesEntry(config))
        if case .success = telegramPendingUploadWrite(transaction: transaction, accountID: draft.accountID, draft: draft, expectedRevision: nil) { return true }
        return false
    }
}
private nonisolated func singleQuoteQueue(_ box: Postbox, receipt: TelegramPendingUploadEnqueueReceipt,
    message: EnqueueMessage, removeQuote: Bool) -> Signal<([MessageId?], Bool), NoError> {
    let accepted = Atomic<Bool>(value: false)
    return enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(99), isSupportUser: false, timestamp: 200,
        peerId: PeerId(receipt.target.chatID), messages: [message],
        transactionAdmission: { receipt.validate(transaction: $0) }, transactionCommit: { transaction, ids in
            if removeQuote, let id = ids.first ?? nil, let queued = transaction.getMessage(id) {
                let attributes = queued.attributes.map { attribute -> MessageAttribute in
                    guard let reply = attribute as? ReplyMessageAttribute else { return attribute }
                    return ReplyMessageAttribute(messageId: reply.messageId, threadMessageId: reply.threadMessageId,
                        quote: nil, isQuote: false, todoItemId: nil)
                }
                transaction.updateMessage(id) { _ in .update(StoreMessage(id: id, globallyUniqueId: nil,
                    groupingKey: queued.groupingKey, threadId: queued.threadId, timestamp: queued.timestamp,
                    flags: [.Unsent], tags: queued.tags, globalTags: queued.globalTags, localTags: queued.localTags,
                    forwardInfo: nil, authorId: PeerId(99), text: queued.text, attributes: attributes, media: queued.media)) }
            }
            _ = accepted.swap(receipt.acknowledge(transaction: transaction, messageIDs: ids))
        }) |> map { ($0, accepted.with { $0 }) }
}

@MainActor final class TelegramComposerReplyPostboxTests: XCTestCase {
    // A stale preflight or dropped selected quote must not authorize/acknowledge
    // a legacy single-file preparation. Uses the real native queue transaction.
    func testLegacySingleUploadChecksCurrentQuoteLimitAndExactQueuedReply() async throws {
        for scenario in ["canonical", "limitShrunk", "quoteDropped"] {
            let box = try await open(root()), peer = PeerId(77)
            let media = TelegramMediaImage(imageId: MediaId(namespace: 0, id: 17), representations: [], immediateThumbnailData: nil,
                reference: nil, partialReference: nil, flags: [])
            let seeded = try await value(replyFixtureMessage(box, peer: peer, text: "prefix selected suffix", media: [media]))
            let original = try XCTUnwrap(seeded)
            let quote = try XCTUnwrap(TelegramReplyQuote(source: try .init(text: original.text), selection: .init(location: 7, length: 8)))
            let source = try XCTUnwrap(telegramMessageActionSource(original, accountID: 99, chatID: peer.toInt64()).quoting(quote))
            let old = try pendingUploadFixture(accountID: 99, chatID: peer.toInt64())
            let draft = TelegramPendingUploadDraft(id: old.id, accountID: 99, chatID: peer.toInt64(), title: "Synthetic",
                captionInput: old.captionInput, originalDraft: nil, replyTarget: .init(source: source), file: old.file,
                disposition: .submissionStarted)
            let freshResult = try await value(validateTelegramReplySource(postbox: box, accountID: 99, source: source))
            let fresh = try XCTUnwrap(freshResult)
            let file = TelegramUploadFile(id: UUID(), name: draft.file.attachment.name, size: draft.file.plaintextByteCount,
                mode: .file, pixelWidth: nil, pixelHeight: nil, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
            let target = TelegramUploadTarget(accountID: 99, chatID: peer.toInt64(), title: "Synthetic", replySource: source)
            let reference = try XCTUnwrap(telegramUploadMedia(file)?.1)
            let message = try XCTUnwrap(telegramUploadMessage(caption: draft.captionInput.formattedText, reference: reference,
                target: target, replySource: fresh))
            let stored = try await value(singleQuoteSeed(box, draft: draft, limit: scenario == "limitShrunk" ? 4 : 1024))
            XCTAssertTrue(stored)
            let receipt = TelegramPendingUploadEnqueueReceipt(preparationID: draft.id, target: target, file: file, caption: draft.captionInput.formattedText)
            let result = try await value(singleQuoteQueue(box, receipt: receipt, message: message, removeQuote: scenario == "quoteDropped"))
            if scenario == "limitShrunk" { XCTAssertTrue(result.0.isEmpty, "Admission revalidates quote length before native insertion") }
            else { XCTAssertEqual(result.0.count, 1) }
            XCTAssertEqual(result.1, scenario == "canonical", "Only the complete exact selected reply receives an acceptance receipt")
        }
    }

    func testUploadQuoteUsesMediaFromFreshNativeValidation() async throws {
        let box = try await open(root())
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77))
        let media = TelegramMediaImage(imageId: MediaId(namespace: 0, id: 17), representations: [], immediateThumbnailData: nil,
            reference: nil, partialReference: nil, flags: [])
        let seeded = try await value(replyFixtureMessage(box, peer: peer, text: "selected caption", media: [media]))
        let original = try XCTUnwrap(seeded)
        let quote = try XCTUnwrap(TelegramReplyQuote(source: try .init(text: original.text), selection: .init(location: 0, length: 8)))
        let source = try XCTUnwrap(telegramMessageActionSource(original, accountID: 99, chatID: peer.toInt64()).quoting(quote))
        let revalidated = try await value(validateTelegramReplySource(postbox: box, accountID: 99, source: source))
        let fresh = try XCTUnwrap(revalidated)
        let target = TelegramUploadTarget(accountID: 99, chatID: peer.toInt64(), title: "Synthetic", replySource: source)
        let mapped = try XCTUnwrap(telegramUploadMessage(caption: try .init(text: "answer"), reference: nil, target: target, replySource: fresh))
        guard case let .message(_, _, _, _, _, reply, _, _, _, _) = mapped else { return XCTFail("Expected native upload message") }
        XCTAssertEqual(reply?.quote?.text, "selected")
        XCTAssertTrue(reply?.quote?.media?.isEqual(to: media) == true)
    }
    func testSelectedQuoteReachesRealNativeQueueAndStaleSourceStopsBeforeInsertion() async throws {
        let box = try await open(root())
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77))
        let seeded = try await value(replyFixtureMessage(box, peer: peer, text: "prefix selected suffix"))
        let original = try XCTUnwrap(seeded)
        let quote = try XCTUnwrap(TelegramReplyQuote(source: try .init(text: original.text), selection: .init(location: 7, length: 8)))
        let source = try XCTUnwrap(telegramMessageActionSource(original, accountID: 99, chatID: peer.toInt64()).quoting(quote))
        let text = try TelegramFormattedText(text: "answer 😀", entities: [.init(offset: 7, length: 2, kind: .bold)])
        let prepared = try await value(quoteReplyMessage(box, source: source, text: text))
        let message = try XCTUnwrap(prepared)
        let ids = try await value(quoteReplyQueue(box, source: source, text: text, message: message))
        let id = try XCTUnwrap(ids.first.flatMap { $0 })
        let queued = try await value(quoteReplyRead(box, id: id))
        let stored = try XCTUnwrap(queued)
        let reply = try XCTUnwrap(stored.attributes.first { $0 is ReplyMessageAttribute } as? ReplyMessageAttribute)
        XCTAssertTrue(reply.isQuote)
        XCTAssertEqual(reply.quote?.text, "selected")
        XCTAssertEqual(reply.quote?.offset, 7)
        XCTAssertEqual(reply.messageId, original.id)
        XCTAssertEqual(stored.text, text.text)
        _ = try await value(replyFixtureMessage(box, peer: peer, text: "prefix changed suffix", update: true))
        let rejected = try await value(quoteReplyQueue(box, source: source, text: text, message: message))
        XCTAssertTrue(rejected.isEmpty)
        let stale = try await value(quoteReplyMessage(box, source: source, text: text))
        XCTAssertNil(stale)
    }
    func testSelectedQuoteResolvesAndRevalidationRetainsItOnlyWhileOriginalStillMatches() async throws {
        let box = try await open(root())
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77)), account: Int64 = 99
        let originalValue = try await value(replyFixtureMessage(box, peer: peer, text: "prefix selected suffix"))
        let original = try XCTUnwrap(originalValue)
        let quote = try XCTUnwrap(TelegramReplyQuote(source: try .init(text: original.text), selection: .init(location: 7, length: 8)))
        let source = try XCTUnwrap(telegramMessageActionSource(original, accountID: account, chatID: peer.toInt64()).quoting(quote))
        let target = TelegramComposerReplyTarget(source: source)
        let resolved = try await value(telegramComposerReply(postbox: box, accountID: account, target: target, chatID: peer.toInt64()))
        XCTAssertEqual(resolved?.source.replyQuote, quote)
        let admitted = try await value(validateTelegramReplySource(postbox: box, accountID: account, source: source))
        XCTAssertEqual(admitted?.replyQuote, quote)
        _ = try await value(replyFixtureMessage(box, peer: peer, text: "prefix changed suffix", update: true))
        let changed = try await value(telegramComposerReply(postbox: box, accountID: account, target: target, chatID: peer.toInt64()))
        XCTAssertNil(changed)
        let stale = try await value(validateTelegramReplySource(postbox: box, accountID: account, source: source))
        XCTAssertNil(stale)
    }
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

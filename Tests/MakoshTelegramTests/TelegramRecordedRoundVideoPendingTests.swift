import XCTest
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private enum RoundQueueForge: CaseIterable, Sendable { case flags, missing, wrong, duplicate, started, unexpected }
private func roundQueuedMessage(_ box: Postbox, id: MessageId) -> Signal<Message?, NoError> {
    box.transaction { $0.getMessage(id) }
}
private func roundQueuePeers(_ box: Postbox, chatTTL: Bool) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peers = [Int64(1),42].map { id in
            TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic round", lastName: nil,
                username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
                emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
                profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        }
        transaction.updatePeersInternal(peers, update: { _,new in new })
        transaction.updatePeerCachedData(peerIds: Set(peers.map(\.id)), update: { _,_ in
            chatTTL ? CachedUserData().withUpdatedAutoremoveTimeout(.known(.init(peerValue: 30))) : CachedUserData()
        })
    }
}
private func roundQueueEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
    messages: [EnqueueMessage], forge: RoundQueueForge?) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages) { messages, admission, commit in
        enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
            peerId: PeerId(42), messages: messages, transactionAdmission: admission, transactionCommit: { transaction, ids in
                if let forge, let first = ids.first, let id = first, let message = transaction.getMessage(id) {
                    var attributes = message.attributes
                    var media = message.media
                    if forge == .flags, let file = media.first as? TelegramMediaFile {
                        media = [file.withUpdatedAttributes([.Video(duration: 2, size: PixelDimensions(width: 200, height: 200),
                            flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil)])]
                    } else {
                        attributes.removeAll { $0 is AutoclearTimeoutMessageAttribute }
                        switch forge {
                        case .flags, .missing: break
                        case .wrong: attributes.append(AutoclearTimeoutMessageAttribute(timeout: 30, countdownBeginTime: nil))
                        case .duplicate:
                            attributes.append(AutoclearTimeoutMessageAttribute(timeout: 2_147_483_647, countdownBeginTime: nil))
                            attributes.append(AutoclearTimeoutMessageAttribute(timeout: 2_147_483_647, countdownBeginTime: nil))
                        case .started: attributes.append(AutoclearTimeoutMessageAttribute(timeout: 2_147_483_647, countdownBeginTime: 100))
                        case .unexpected: attributes.append(AutoclearTimeoutMessageAttribute(timeout: 2_147_483_647, countdownBeginTime: nil))
                        }
                    }
                    transaction.updateMessage(id) { _ in .update(StoreMessage(id: id, globallyUniqueId: nil,
                        groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp,
                        flags: [.Unsent], tags: message.tags, globalTags: message.globalTags, localTags: message.localTags,
                        forwardInfo: nil, authorId: PeerId(1), text: message.text, attributes: attributes, media: media)) }
                }
                commit(transaction, ids)
            })
    }
}

@MainActor final class TelegramRecordedRoundVideoPendingTests: XCTestCase {
    func testLocalRoundRestoresAndQueuesAfterEncryptedPostboxReopen() async throws { try await reopen(s3: false, once: false) }
    func testS3RoundRestoresAndQueuesAfterEncryptedPostboxReopen() async throws { try await reopen(s3: true, once: false) }
    func testLocalOnceRoundRestoresAndQueuesAfterEncryptedPostboxReopen() async throws { try await reopen(s3: false, once: true) }
    func testS3OnceRoundRestoresAndQueuesAfterEncryptedPostboxReopen() async throws { try await reopen(s3: true, once: true) }
    func testRoundReceiptRefusesChangedNativeFlagsAndLifetime() async throws {
        for forge in RoundQueueForge.allCases { try await reopen(s3: false, once: forge != .unexpected && forge != .flags, forge: forge) }
    }
    func testRoundOneTimeAndChatWideAutoDeleteRemainIndependent() async throws { try await reopen(s3: false, once: true, chatTTL: true) }

    // A rejected caption must leave no new S3 copy, including transient preparation.
    func testInvalidRoundOptionsRefuseBeforeArchiveCapture() async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try config(), archiveRoot = try root(), box = try await open(root())
        let archive = try archive(database, configuration, archiveRoot)
        try await archive.setConversationFileSavingEnabled(identity: .init(service: "telegram", accountID: "1",
            conversationID: "42", messageID: "synthetic-policy"), enabled: true)
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic round")
        let store = session(box, archive)
        let bytes = try await recordedRoundVideoFixtureBytes(duration: 1.25)
        let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
        defer { try? TelegramUploadFileIO.discard(file) }
        let item = TelegramUploadBatchItem(id: file.id, file: file)
        for (caption, grouped, spoiler) in [("Caption",false,false),("",true,false),("",false,true)] {
            do {
                try await store.prepare(preparationID: UUID(), items: [item], isGrouped: grouped, presentation: .media,
                    target: target, captionInput: TelegramComposerInput(formattedText: .init(text: caption)),
                    mediaSpoiler: spoiler, originalDraft: nil)
                XCTFail("Invalid recorded options admitted")
            } catch is TelegramPendingUploadPersistenceError {}
        }
        XCTAssertEqual(try database.execute("SELECT count(*) FROM \"\(database.schema)\".archive_file_events"), [["0"]])
        let pointer = try await store.load(chatID: 42); XCTAssertNil(pointer)
    }

    // A cover editor cannot create an archived cover for a round preparation,
    // even if its caller strips the staged file's typed metadata.
    func testRoundCoverEditRefusesBeforeAnyNewArchiveCopy() async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try config(), archiveRoot = try root(), box = try await open(root())
        let archive = try archive(database, configuration, archiveRoot), store = session(box, archive)
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic round")
        try await archive.setConversationFileSavingEnabled(identity: .init(service: "telegram", accountID: "1",
            conversationID: "42", messageID: "synthetic-policy"), enabled: true)
        let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: recordedRoundVideoFixtureBytes(duration: 1.25))
        defer { try? TelegramUploadFileIO.discard(file) }
        let id = UUID(), item = TelegramUploadBatchItem(id: file.id, file: file)
        try await store.prepare(preparationID: id, items: [item], isGrouped: false, presentation: .media,
            target: target, captionInput: .empty, originalDraft: nil)
        let before = try await store.load(chatID: 42)
        let initialEvents = try database.execute("SELECT count(*) FROM \"\(database.schema)\".archive_file_events")
        let image = try root().appendingPathComponent("cover.jpg")
        try writeUploadVideoCoverFixture(image)
        let cover = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(cover.imageFile) }
        let untyped = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: file.mode,
            pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: file.url, directory: file.directory, video: file.video)
        for supplied in [file, untyped] {
            do {
                try await store.replaceVideoCover(preparationID: id, itemID: item.id, file: supplied, target: target, cover: cover)
                XCTFail("Round cover admitted")
            } catch is TelegramPendingUploadPersistenceError {}
            XCTAssertEqual(try database.execute("SELECT count(*) FROM \"\(database.schema)\".archive_file_events"), initialEvents)
            let pointer = try await store.load(chatID: 42); XCTAssertEqual(pointer, before)
        }
    }

    // Real encrypted recovery, S3 policy and native enqueue; only server I/O is absent.
    private func reopen(s3: Bool, once: Bool, forge: RoundQueueForge? = nil, chatTTL: Bool = false) async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try config(), archiveRoot = try root(), postboxRoot = try root()
        let archive = try archive(database, configuration, archiveRoot)
        let policy = MessageArchiveIdentity(service: "telegram", accountID: "1", conversationID: "42", messageID: "synthetic-policy")
        try await archive.setConversationFileSavingEnabled(identity: policy, enabled: s3)
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic round")
        let bytes = try await recordedRoundVideoFixtureBytes(duration: 1.25)
        var saved: TelegramPendingUploadDraft?
        do {
            let box = try await open(postboxRoot); previousBox = box
            let store = session(box, archive)
            let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes, isOneTime: once)
            defer { try? TelegramUploadFileIO.discard(file) }
            let item = TelegramUploadBatchItem(id: file.id, file: file), id = UUID()
            try await store.prepare(preparationID: id, items: [item], isGrouped: false, presentation: .media,
                target: target, captionInput: .empty, originalDraft: nil)
            let firstLoad = try await store.load(chatID: 42), first = try XCTUnwrap(firstLoad)
            XCTAssertEqual(first.schemaVersion, 13); XCTAssertEqual(first.items[0].metadata?.roundVideo?.isOneTime, once)
            XCTAssertEqual(first.items[0].metadata?.roundVideo?.nativeDuration, 2)
            XCTAssertEqual(first.items[0].file.state, s3 ? .stored : .local)
            let ready = try await store.restoreItems(draft: first)
            defer { for item in ready { try? item.discard() } }
            XCTAssertEqual(ready.count, 1); XCTAssertEqual(try Data(contentsOf: ready[0].file.url), bytes)
            try await store.save(preparationID: id, chatID: 42, captionInput: .empty, disposition: .submissionStarted)
            saved = try await store.load(chatID: 42)
        }
        try await released()
        let frozen = try XCTUnwrap(saved), record = frozen.items[0].file
        let remote = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey)
        if s3 { XCTAssertNotNil(remote) } else { XCTAssertNil(remote) }
        do {
            let box = try await open(postboxRoot); previousBox = box
            let store = session(box, archive), loaded = try await store.load(chatID: 42)
            XCTAssertEqual(loaded, frozen)
            let restored = try await store.restoreItems(draft: frozen)
            defer { for item in restored { try? item.discard() } }
            XCTAssertEqual(try Data(contentsOf: restored[0].file.url), bytes)
            XCTAssertEqual(restored[0].file.metadata, frozen.items[0].metadata)
            let peers = expectation(description: "Synthetic round peers")
            let seed = (roundQueuePeers(box, chatTTL: chatTTL) |> deliverOnMainQueue).start(next: { peers.fulfill() })
            defer { seed.dispose() }; await fulfillment(of: [peers], timeout: 20)
            let done = expectation(description: "Native round admission")
            var result: TelegramUploadBatchEvent?
            let submission = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: restored, draft: frozen,
                target: target, enqueue: { receipt, messages in roundQueueEnqueue(box, receipt: receipt, messages: messages, forge: forge) }) {
                    switch $0 { case .accepted, .rejected, .uncertain: result = $0; done.fulfill(); default: break }
                }
            defer { submission.stop() }; await fulfillment(of: [done], timeout: 20)
            if forge != nil {
                XCTAssertEqual(result, .uncertain)
                let pointer = try await store.load(chatID: 42); XCTAssertEqual(pointer, frozen)
                XCTAssertEqual(try Data(contentsOf: restored[0].file.url), bytes)
                return
            }
            guard case let .accepted(ids) = result, let id = ids.first else { return XCTFail("Native round was not accepted: \(String(describing: result))") }
            XCTAssertEqual(ids.count, 1)
            let read = expectation(description: "Read native round")
            var message: Message?
            let reading = (roundQueuedMessage(box, id: id.nativeID) |> deliverOnMainQueue).start(next: { message = $0; read.fulfill() })
            defer { reading.dispose() }; await fulfillment(of: [read], timeout: 20)
            let native = try XCTUnwrap(message?.media.first as? TelegramMediaFile)
            XCTAssertEqual(message?.text, ""); XCTAssertNil(message?.groupingKey)
            XCTAssertEqual(native.mimeType, "video/mp4"); XCTAssertNil(native.size)
            XCTAssertEqual(native.attributes, [.Video(duration: 2, size: PixelDimensions(width: 200, height: 200),
                flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)])
            XCTAssertEqual(native.previewRepresentations.count, 1)
            let ttl = message?.attributes.compactMap { $0 as? AutoclearTimeoutMessageAttribute } ?? []
            XCTAssertEqual(ttl.count, once ? 1 : 0)
            if once { XCTAssertEqual(ttl[0].timeout, 2_147_483_647); XCTAssertNil(ttl[0].countdownBeginTime) }
            let chat = message?.attributes.compactMap { $0 as? AutoremoveTimeoutMessageAttribute } ?? []
            XCTAssertEqual(chat.count, chatTTL ? 1 : 0)
            if chatTTL { XCTAssertEqual(chat[0].timeout, 30) }
            let cacheDone = expectation(description: "Exact native round bytes"); var data: MediaResourceData?
            let cache = (box.mediaBox.resourceData(native.resource, pathExtension: nil, option: .complete(waitUntilFetchStatus: false))
                |> take(1) |> deliverOnMainQueue).start(next: { data = $0; cacheDone.fulfill() })
            defer { cache.dispose() }; await fulfillment(of: [cacheDone], timeout: 20)
            let payload = try XCTUnwrap(data); XCTAssertTrue(payload.complete)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: payload.path)), bytes)
            let accepted = try await store.load(chatID: 42)
            XCTAssertEqual(accepted?.disposition, .acceptedBatch(messageIDs: ids)); XCTAssertEqual(accepted?.items, frozen.items)
            saved = accepted
            let staleDone = expectation(description: "Accepted round cannot resend")
            let stale = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: restored, draft: frozen,
                target: target, enqueue: { receipt, messages in roundQueueEnqueue(box, receipt: receipt, messages: messages, forge: nil) }) {
                    switch $0 { case .rejected: staleDone.fulfill(); case .accepted, .uncertain: XCTFail("Stale resend"); staleDone.fulfill(); default: break }
                }
            defer { stale.stop() }; await fulfillment(of: [staleDone], timeout: 20)
        }
        try await released()
        let box = try await open(postboxRoot), reopened = try await session(box, archive).load(chatID: 42)
        XCTAssertEqual(reopened, saved)
        if !s3 {
            XCTAssertEqual(try database.execute("SELECT count(*) FROM \"\(database.schema)\".archive_file_events"), [["0"]])
            try await archive.setConversationFileSavingEnabled(identity: policy, enabled: true)
            let count = try await archive.resume(); XCTAssertEqual(count, 0)
            let absent = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey); XCTAssertNil(absent)
        }
    }
    private func config() throws -> S3ObjectStoreConfiguration {
        try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
    }
    private func archive(_ database: PendingFilesTestDatabase, _ configuration: S3ObjectStoreConfiguration, _ root: URL) throws -> ArchiveFileRepository {
        try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema, configuration: configuration,
            spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _,_ in Data(repeating: 0x68, count: 32) })
    }
    private func session(_ box: Postbox, _ archive: ArchiveFileRepository) -> TelegramPendingUploadSession {
        TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
            files: { TelegramPendingUploadFiles(repository: archive) })
    }
    private weak var previousBox: Postbox?
    private func released() async throws {
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
    }
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: path) }; return path
    }
    private func open(_ root: URL) async throws -> Postbox {
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Encrypted round fixture"); var box: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false, isReadOnly: false,
            useCopy: false, useCaches: false, removeDatabaseOnError: false) |> deliverOnMainQueue).start(next: {
                if case let .postbox(value) = $0 { box = value; opened.fulfill() }
            })
        defer { opening.dispose() }; await fulfillment(of: [opened], timeout: 20)
        let result = try XCTUnwrap(box), ready = expectation(description: "Round MediaBox stores ready")
        ready.expectedFulfillmentCount = 2
        let storage = (result.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        let cache = (result.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        defer { storage.dispose(); cache.dispose() }; await fulfillment(of: [ready], timeout: 20)
        return result
    }
}

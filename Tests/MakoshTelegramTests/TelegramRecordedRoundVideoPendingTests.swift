import XCTest
import AVFoundation
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private enum RoundQueueForge: CaseIterable, Sendable { case flags, missing, wrong, duplicate, started, unexpected }
private enum RoundQueueAccess: CaseIterable, Sendable {
    case instantBanned, voiceAndVideoBanned, slowDeadline, slowFuture, slowPending, privacy, paid, invalidClock
    var isChannel: Bool { self != .privacy && self != .paid && self != .invalidClock }
    var allowed: Bool { self == .voiceAndVideoBanned || self == .slowDeadline }
}
private func roundQueuedMessage(_ box: Postbox, id: MessageId) -> Signal<Message?, NoError> {
    box.transaction { $0.getMessage(id) }
}
private func roundQueuePeers(_ box: Postbox, chatTTL: Bool, chatID: Int64 = 42,
    access: RoundQueueAccess? = nil) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peers = [Int64(1),42,10001].map { id in
            TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic round", lastName: nil,
                username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
                emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
                profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        }
        transaction.updatePeersInternal(peers, update: { _,new in new })
        transaction.updatePeerCachedData(peerIds: Set(peers.map(\.id)), update: { _,_ in
            chatTTL ? CachedUserData().withUpdatedAutoremoveTimeout(.known(.init(peerValue: 30))) : CachedUserData()
        })
        if let access, access.isChannel {
            let id = PeerId(chatID)
            let slow = access == .slowDeadline || access == .slowFuture || access == .slowPending
            let ban: TelegramChatBannedRightsFlags = access == .instantBanned ? [.banSendInstantVideos] :
                access == .voiceAndVideoBanned ? [.banSendVoice, .banSendVideos] : []
            let channel = TelegramChannel(id: id, accessHash: nil, title: "Synthetic round permissions", username: nil,
                photo: [], creationDate: 0, version: 1, participationStatus: .member,
                info: .group(TelegramChannelGroupInfo(flags: slow ? [.slowModeEnabled] : [])), flags: [], restrictionInfo: nil,
                adminRights: nil, bannedRights: nil,
                defaultBannedRights: TelegramChatBannedRights(flags: ban, untilDate: Int32.max), usernames: [], storiesHidden: nil,
                nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
                emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil,
                verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
            transaction.updatePeersInternal([channel], update: { _,new in new })
            transaction.updatePeerCachedData(peerIds: [id], update: { _,_ in
                slow ? CachedChannelData().withUpdatedSlowModeTimeout(30)
                    .withUpdatedSlowModeValidUntilTimestamp(access == .slowFuture ? 101 : 100) : CachedChannelData()
            })
            if access == .slowPending {
                _ = transaction.addMessages([StoreMessage(id: MessageId(peerId: id, namespace: Namespaces.Message.Local, id: 1),
                    globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 99, flags: [.Unsent], tags: [], globalTags: [],
                    localTags: [], forwardInfo: nil, authorId: PeerId(1), text: "Synthetic previous pending",
                    attributes: [], media: [])], location: .Random)
            }
        } else if let access, access == .privacy || access == .paid {
            transaction.updatePeerCachedData(peerIds: [PeerId(chatID)], update: { _,_ in
                access == .privacy ? CachedUserData().withUpdatedVoiceMessagesAvailable(false) :
                    CachedUserData().withUpdatedSendPaidMessageStars(.init(value: 1, nanos: 0))
            })
        }
    }
}
private func roundQueueEnqueue(_ box: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
    messages: [EnqueueMessage], forge: RoundQueueForge?, timestamp: TimeInterval = 100) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages, now: { timestamp }) { messages, admission, commit in
        enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(1), isSupportUser: false, timestamp: 100,
            peerId: PeerId(receipt.target.chatID), messages: messages, transactionAdmission: admission, transactionCommit: { transaction, ids in
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
    #if DEBUG
    func testModelLocalRoundRechecksRightsBeforeDurableSend() async throws { try await controllerQueue(s3: false, once: false, modelDriven: true) }
    func testModelS3RoundRechecksRightsBeforeDurableSend() async throws { try await controllerQueue(s3: true, once: false, modelDriven: true) }
    func testModelLocalOnceRoundRetainsFrozenIntentAfterDeniedSend() async throws { try await controllerQueue(s3: false, once: true, modelDriven: true) }
    func testModelS3OnceRoundRetainsFrozenIntentAfterDeniedSend() async throws { try await controllerQueue(s3: true, once: true, modelDriven: true) }
    #endif
    func testLocalControllerRoundRestoresAndSendsOnlyExplicitly() async throws { try await controllerQueue(s3: false, once: false) }
    func testS3ControllerRoundRestoresAndSendsOnlyExplicitly() async throws { try await controllerQueue(s3: true, once: false) }
    func testLocalControllerOnceRoundRestoresAndSendsOnlyExplicitly() async throws { try await controllerQueue(s3: false, once: true) }
    func testS3ControllerOnceRoundRestoresAndSendsOnlyExplicitly() async throws { try await controllerQueue(s3: true, once: true) }
    func testLocalRoundRestoresAndQueuesAfterEncryptedPostboxReopen() async throws { try await reopen(s3: false, once: false) }
    func testS3RoundRestoresAndQueuesAfterEncryptedPostboxReopen() async throws { try await reopen(s3: true, once: false) }
    func testLocalOnceRoundRestoresAndQueuesAfterEncryptedPostboxReopen() async throws { try await reopen(s3: false, once: true) }
    func testS3OnceRoundRestoresAndQueuesAfterEncryptedPostboxReopen() async throws { try await reopen(s3: true, once: true) }
    func testRoundReceiptRefusesChangedNativeFlagsAndLifetime() async throws {
        for forge in RoundQueueForge.allCases { try await reopen(s3: false, once: forge != .unexpected && forge != .flags, forge: forge) }
    }
    func testRoundOneTimeAndChatWideAutoDeleteRemainIndependent() async throws { try await reopen(s3: false, once: true, chatTTL: true) }
    // Catches skipping a fresh native admission check, confusing video/voice
    // bans with instant-video rights, and counting this same queue insertion as
    // an earlier pending message during slow-mode acknowledgement.
    func testRoundNativeAdmissionUsesFreshRightsPrivacyFeeAndSlowMode() async throws {
        for access in RoundQueueAccess.allCases { try await reopen(s3: false, once: false, access: access) }
    }

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
    private func reopen(s3: Bool, once: Bool, forge: RoundQueueForge? = nil, chatTTL: Bool = false,
        access: RoundQueueAccess? = nil) async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try config(), archiveRoot = try root(), postboxRoot = try root()
        let archive = try archive(database, configuration, archiveRoot)
        let chatID = access?.isChannel == true ? PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(92)).toInt64() : 42
        let policy = MessageArchiveIdentity(service: "telegram", accountID: "1", conversationID: String(chatID), messageID: "synthetic-policy")
        try await archive.setConversationFileSavingEnabled(identity: policy, enabled: s3)
        let target = TelegramUploadTarget(accountID: 1, chatID: chatID, title: "Synthetic round")
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
            let firstLoad = try await store.load(chatID: chatID), first = try XCTUnwrap(firstLoad)
            XCTAssertEqual(first.schemaVersion, 13); XCTAssertEqual(first.items[0].metadata?.roundVideo?.isOneTime, once)
            XCTAssertEqual(first.items[0].metadata?.roundVideo?.nativeDuration, 2)
            XCTAssertEqual(first.items[0].file.state, s3 ? .stored : .local)
            let ready = try await store.restoreItems(draft: first)
            defer { for item in ready { try? item.discard() } }
            XCTAssertEqual(ready.count, 1); XCTAssertEqual(try Data(contentsOf: ready[0].file.url), bytes)
            try await store.save(preparationID: id, chatID: chatID, captionInput: .empty, disposition: .submissionStarted)
            saved = try await store.load(chatID: chatID)
        }
        try await released()
        let frozen = try XCTUnwrap(saved), record = frozen.items[0].file
        let remote = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey)
        if s3 { XCTAssertNotNil(remote) } else { XCTAssertNil(remote) }
        do {
            let box = try await open(postboxRoot); previousBox = box
            let store = session(box, archive), loaded = try await store.load(chatID: chatID)
            XCTAssertEqual(loaded, frozen)
            let restored = try await store.restoreItems(draft: frozen)
            defer { for item in restored { try? item.discard() } }
            XCTAssertEqual(try Data(contentsOf: restored[0].file.url), bytes)
            XCTAssertEqual(restored[0].file.metadata, frozen.items[0].metadata)
            let peers = expectation(description: "Synthetic round peers")
            let seed = (roundQueuePeers(box, chatTTL: chatTTL, chatID: chatID, access: access) |> deliverOnMainQueue).start(next: { peers.fulfill() })
            defer { seed.dispose() }; await fulfillment(of: [peers], timeout: 20)
            let done = expectation(description: "Native round admission")
            var result: TelegramUploadBatchEvent?
            let submission = TelegramUploadBatchSubmission(postbox: box, accountID: 1, items: restored, draft: frozen,
                target: target, enqueue: { receipt, messages in
                    roundQueueEnqueue(box, receipt: receipt, messages: messages, forge: forge,
                        timestamp: access == .invalidClock ? .nan : 100)
                }) {
                    switch $0 { case .accepted, .rejected, .uncertain: result = $0; done.fulfill(); default: break }
                }
            defer { submission.stop() }; await fulfillment(of: [done], timeout: 20)
            if let access, !access.allowed {
                XCTAssertEqual(result, .rejected, "Unexpected admission for \(access)")
                let pointer = try await store.load(chatID: chatID); XCTAssertEqual(pointer, frozen)
                return
            }
            if forge != nil {
                XCTAssertEqual(result, .uncertain)
                let pointer = try await store.load(chatID: chatID); XCTAssertEqual(pointer, frozen)
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
            let accepted = try await store.load(chatID: chatID)
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
        let box = try await open(postboxRoot), reopened = try await session(box, archive).load(chatID: chatID)
        XCTAssertEqual(reopened, saved)
        if !s3 {
            XCTAssertEqual(try database.execute("SELECT count(*) FROM \"\(database.schema)\".archive_file_events"), [["0"]])
            try await archive.setConversationFileSavingEnabled(identity: policy, enabled: true)
            let count = try await archive.resume(); XCTAssertEqual(count, 0)
            let absent = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey); XCTAssertNil(absent)
        }
    }
    // Catches schema13 restore/send allowlists, accidental resume-send and S3
    // policy regressions at the actual controller→durable→native queue boundary.
    private func controllerQueue(s3: Bool, once: Bool, modelDriven: Bool = false) async throws {
        let accountID: Int64 = modelDriven ? -1 : 1, chatID: Int64 = modelDriven ? 10001 : 42
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try config(), archiveRoot = try root(), postboxRoot = try root()
        let archive = try archive(database, configuration, archiveRoot)
        let policy = MessageArchiveIdentity(service: "telegram", accountID: String(accountID), conversationID: String(chatID), messageID: "synthetic-policy")
        try await archive.setConversationFileSavingEnabled(identity: policy, enabled: s3)
        let target = TelegramUploadTarget(accountID: accountID, chatID: chatID, title: "Synthetic round")
        let bytes = try await recordedRoundVideoFixtureBytes(duration: 1.25)
        var accepted: TelegramPendingUploadDraft?
        do {
            let box = try await open(postboxRoot); previousBox = box
            let seeded = expectation(description: "Controller synthetic round peers")
            let seed = (roundQueuePeers(box, chatTTL: false) |> deliverOnMainQueue).start(next: { seeded.fulfill() })
            defer { seed.dispose() }; await fulfillment(of: [seeded], timeout: 20)
            let store = session(box, archive, accountID: accountID), provider = RoundLocalQueueProvider(box, accountID: accountID)
            #if DEBUG
            let model = modelDriven ? TelegramModel.syntheticPreview() : nil
            model?.selectedChatID = chatID
            var controller = model?.upload ?? TelegramUploadController()
            #else
            var controller = TelegramUploadController()
            #endif
            controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
            defer { controller.bind(provider: nil) }
            #if DEBUG
            if let model {
                let capture = ModelPendingRoundCapture(bytes)
                model.voiceRecording.toggleKind()
                model.voiceRecording.authorizeRoundVideo = { true }
                model.voiceRecording.makeRoundVideoCapture = { capture }
                var checks = 0, onceChecks = 0
                model.voiceRecording.roundVideoEligibility = { _ in
                    checks += 1; return checks <= 2 ? .allowed : .voicePrivacy
                }
                model.voiceRecording.roundVideoOneTimeEligibility = { _ in onceChecks += 1; return onceChecks == 1 }
                // Voice ACL must never authorize the round recording or final send.
                model.voiceRecording.eligibility = { _ in .restricted }
                model.beginVoiceRecording()
                for _ in 0..<1_000 where model.voiceRecording.phase == .authorizing { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(model.voiceRecording.phase, .recording)
                if once {
                    model.voiceRecording.move(upward: 101); model.voiceRecording.setOneTime(true)
                    XCTAssertTrue(model.voiceRecording.isOneTime); model.voiceRecording.send()
                } else { model.voiceRecording.release(inside: true) }
                for _ in 0..<1_000 where model.voiceRecording.isActive { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(model.voiceRecording.phase, .idle)
                XCTAssertEqual(controller.phase, .ready); XCTAssertEqual(provider.submissions, 0)
                guard controller.phase == .ready else { return }
                XCTAssertNotNil(model.error)
            } else {
                guard controller.prepareRecordedRoundVideo(bytes: bytes, target: target, isOneTime: once) else {
                    return XCTFail("Controller refused explicit round recording")
                }
            }
            #else
            XCTAssertTrue(controller.prepareRecordedRoundVideo(bytes: bytes, target: target, isOneTime: once))
            #endif
            for _ in 0..<1_000 where !controller.canSend && controller.phase != .failed {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(controller.canSend); XCTAssertEqual(controller.phase, .ready)
            let stage = try XCTUnwrap(controller.file), loaded = try await store.load(chatID: chatID)
            let prepared = try XCTUnwrap(loaded)
            XCTAssertEqual(prepared.schemaVersion, 13); XCTAssertEqual(prepared.disposition, .prepared)
            XCTAssertEqual(prepared.items.first?.metadata?.roundVideo?.isOneTime, once)
            XCTAssertEqual(prepared.items.first?.file.state, s3 ? .stored : .local)
            #if DEBUG
            if let model {
                model.voiceRecording.roundVideoEligibility = { _ in .allowed }
                model.voiceRecording.roundVideoOneTimeEligibility = { _ in true }
                model.sendPreparedVoice(contextID: prepared.id)
            }
            #endif
            if !modelDriven {
            await controller.openRoundVideoPreview(contextID: prepared.id)
            guard let originalPlayer = controller.videoPlayback.player else {
                return XCTFail("Prepared round preview is not attached before recovery")
            }
            XCTAssertEqual((originalPlayer.currentItem?.asset as? AVURLAsset)?.url, stage.url)
            XCTAssertTrue(originalPlayer.isMuted); XCTAssertEqual(originalPlayer.volume, 0)
            controller.bind(provider: nil)
            XCTAssertNil(originalPlayer.currentItem)
            let recovered = try await store.restoreItems(draft: prepared)
            controller = TelegramUploadController()
            controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
            guard controller.restore(draft: prepared, items: recovered, target: target,
                restorationEpoch: controller.recoveryRestoreEpoch) else {
                for item in recovered { try? item.discard() }
                return XCTFail("Controller refused schema13 recovery")
            }
            XCTAssertEqual(controller.phase, .ready); XCTAssertTrue(controller.isRecordedRoundVideo)
            XCTAssertEqual(controller.isOneTimeRoundVideo, once); XCTAssertFalse(controller.canEditVideoCover)
            XCTAssertFalse(controller.canUseMediaOptions); XCTAssertFalse(controller.showsPreparationPreview)
            XCTAssertEqual(provider.submissions, 0); XCTAssertTrue(controller.canSend)
            await controller.openRoundVideoPreview(contextID: prepared.id)
            guard let restoredPlayer = controller.videoPlayback.player else {
                return XCTFail("Restored round preview is not attached before explicit Send")
            }
            XCTAssertEqual((restoredPlayer.currentItem?.asset as? AVURLAsset)?.url, controller.file?.url)
            XCTAssertTrue(restoredPlayer.isMuted); XCTAssertEqual(restoredPlayer.volume, 0)
            XCTAssertEqual(controller.isOneTimeRoundVideo, once)
            controller.send(contextID: UUID()); XCTAssertEqual(provider.submissions, 0)
            XCTAssertTrue(controller.videoPlayback.player === restoredPlayer)
            controller.send(contextID: prepared.id)
            XCTAssertNil(restoredPlayer.currentItem, "Detach before durable submission or native queue insertion")
            XCTAssertNil(controller.videoPlayback.player)
            }
            for _ in 0..<1_000 where controller.phase == .ready || controller.phase == .storing || controller.phase == .enqueuing {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(controller.phase, .queued(nil)); XCTAssertEqual(provider.submissions, 1)
            let saved = try await store.load(chatID: chatID), value = try XCTUnwrap(saved)
            guard case let .acceptedBatch(ids) = value.disposition, let id = ids.first else {
                return XCTFail("Controller did not retain native round admission")
            }
            XCTAssertEqual(value.items, prepared.items); XCTAssertEqual(controller.messageIDs, ids.map(\.description))
            let read = expectation(description: "Controller round native result"); var message: Message?
            let reading = (roundQueuedMessage(box, id: id.nativeID) |> deliverOnMainQueue).start(next: { message = $0; read.fulfill() })
            defer { reading.dispose() }; await fulfillment(of: [read], timeout: 20)
            let media = try XCTUnwrap(message?.media.first as? TelegramMediaFile)
            XCTAssertEqual(media.attributes, [.Video(duration: 2, size: PixelDimensions(width: 200, height: 200),
                flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)])
            let ttl = message?.attributes.compactMap { $0 as? AutoclearTimeoutMessageAttribute } ?? []
            XCTAssertEqual(ttl.count, once ? 1 : 0)
            if once { XCTAssertEqual(ttl.first?.timeout, 2_147_483_647); XCTAssertNil(ttl.first?.countdownBeginTime) }
            let complete = expectation(description: "Controller round native bytes"); var payload: MediaResourceData?
            let cache = (box.mediaBox.resourceData(media.resource, pathExtension: nil, option: .complete(waitUntilFetchStatus: false))
                |> take(1) |> deliverOnMainQueue).start(next: { payload = $0; complete.fulfill() })
            defer { cache.dispose() }; await fulfillment(of: [complete], timeout: 20)
            let data = try XCTUnwrap(payload); XCTAssertTrue(data.complete)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: data.path)), bytes)
            controller.send(); controller.send(contextID: prepared.id); XCTAssertEqual(provider.submissions, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.directory.path))
            accepted = value
        }
        try await released()
        let frozen = try XCTUnwrap(accepted), box = try await open(postboxRoot), store = session(box, archive, accountID: accountID)
        let loaded = try await store.load(chatID: chatID); XCTAssertEqual(loaded, frozen)
        let restored = try await store.restoreItems(draft: frozen)
        defer { for item in restored { try? item.discard() } }
        let controller = TelegramUploadController(), provider = RoundLocalQueueProvider(box, accountID: accountID)
        controller.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        XCTAssertFalse(controller.restore(draft: frozen, items: restored, target: target, restorationEpoch: controller.recoveryRestoreEpoch))
        controller.send(); XCTAssertEqual(provider.submissions, 0)
        let record = frozen.items[0].file
        let remote = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey)
        if s3 { XCTAssertNotNil(remote) }
        else {
            XCTAssertNil(remote)
            XCTAssertEqual(try database.execute("SELECT count(*) FROM \"\(database.schema)\".archive_file_events"), [["0"]])
            try await archive.setConversationFileSavingEnabled(identity: policy, enabled: true)
            let resumed = try await archive.resume(); XCTAssertEqual(resumed, 0)
            let stillAbsent = try await S3ObjectStore(configuration: configuration).head(key: record.objectKey)
            XCTAssertNil(stillAbsent)
        }
    }
    private func config() throws -> S3ObjectStoreConfiguration {
        try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
    }
    private func archive(_ database: PendingFilesTestDatabase, _ configuration: S3ObjectStoreConfiguration, _ root: URL) throws -> ArchiveFileRepository {
        try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema, configuration: configuration,
            spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _,_ in Data(repeating: 0x68, count: 32) })
    }
    private func session(_ box: Postbox, _ archive: ArchiveFileRepository, accountID: Int64 = 1) -> TelegramPendingUploadSession {
        TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: accountID),
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

@MainActor private final class RoundLocalQueueProvider: TelegramUploadBatchProvider {
    let accountID: Int64
    private let box: Postbox
    private(set) var submissions = 0
    init(_ box: Postbox, accountID: Int64 = 1) { self.box = box; self.accountID = accountID }
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
        receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        submissions += 1
        return TelegramUploadBatchSubmission(postbox: box, accountID: accountID, items: items, draft: draft, target: target,
            enqueue: { [box] receipt, messages in
                roundQueueEnqueue(box, receipt: receipt, messages: messages, forge: nil)
            }, receive: receive)
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID,
        caption: TelegramFormattedText, captionAboveMedia: Bool, mediaSpoiler: Bool,
        receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Round recording must use complete typed batch receipt")
        receive(.rejected); return RoundUnusedLease()
    }
}
@MainActor private final class RoundUnusedLease: TelegramUploadLease { func stop() {} }

#if DEBUG
@MainActor private final class ModelPendingRoundCapture: TelegramRoundVideoCapture {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    var isRecording = false
    var duration: Double { 1.25 }; var level: Float { 0.5 }
    var previewSession: AVCaptureSession? { nil }
    func start() async throws { isRecording = true }
    func stop() async throws -> Data { isRecording = false; return bytes }
    func cancel() { isRecording = false }
}
#endif

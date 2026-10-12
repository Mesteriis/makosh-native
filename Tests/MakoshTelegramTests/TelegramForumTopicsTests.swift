import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func forumPeer(_ number: Int64 = 42, flags: TelegramChannelFlags = [.isForum]) -> TelegramChannel {
    TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(number)),
        accessHash: nil, title: "Synthetic forum", username: nil, photo: [], creationDate: 0, version: 1,
        participationStatus: .member, info: .group(TelegramChannelGroupInfo(flags: [])), flags: flags,
        restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [],
        storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
        profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil,
        subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
}

private nonisolated func forumData(title: String = "General", unread: Int32 = 0,
    closed: Bool = false, hidden: Bool = false, owned: Bool = false,
    mute: PeerMuteState = .unmuted, sound: PeerMessageSound = .default) -> MessageHistoryThreadData {
    MessageHistoryThreadData(creationDate: 1, isOwnedByMe: owned,
        author: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(1)),
        info: .init(title: title, icon: 99, iconColor: 0x6fb9f0), incomingUnreadCount: unread,
        isMarkedUnread: unread > 0, maxIncomingReadId: 1, maxKnownMessageId: 10,
        maxOutgoingReadId: 1, isClosed: closed, isHidden: hidden,
        notificationSettings: TelegramPeerNotificationSettings(muteState: mute, messageSound: sound,
            displayPreviews: .default, storySettings: .default), isMessageFeeRemoved: false)
}

private nonisolated func forumStored(_ data: MessageHistoryThreadData) -> StoredMessageHistoryThreadInfo {
    StoredMessageHistoryThreadInfo(data: CodableEntry(data)!, summary: .init(
        totalUnreadCount: data.incomingUnreadCount, isMarkedUnread: data.isMarkedUnread,
        mutedUntil: nil, maxOutgoingReadId: data.maxOutgoingReadId))
}

private nonisolated func forumSeed(_ box: Postbox, number: Int64 = 42,
    flags: TelegramChannelFlags = [.isForum], loaded: Bool = true,
    topics: [(Int64, Int32, MessageHistoryThreadData)] = [(1, 100, forumData())]) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let peer = forumPeer(number, flags: flags)
        transaction.updatePeersInternal([peer], update: { _, new in new })
        transaction.setPeerThreadCombinedState(peerId: peer.id, state: loaded ? StoredPeerThreadCombinedState(
            data: CodableEntry(data: Data()), validIndexBoundary: .init(timestamp: 0, threadId: 0, messageId: 1)) : nil)
        for (offset, topic) in topics.enumerated() {
            let (thread, timestamp, data) = topic
            _ = transaction.addMessages([StoreMessage(id: MessageId(peerId: peer.id,
                namespace: Namespaces.Message.Cloud, id: Int32(offset + 10)), globallyUniqueId: nil,
                groupingKey: nil, threadId: thread, timestamp: timestamp, flags: [.Incoming], tags: [],
                globalTags: [], localTags: [], forwardInfo: nil, authorId: nil,
                text: "Synthetic topic \(thread)", attributes: [], media: [])], location: .Random)
            transaction.setMessageHistoryThreadInfo(peerId: peer.id, threadId: thread, info: forumStored(data))
        }
        return true
    }
}

private nonisolated func forumChangePeer(_ box: Postbox, flags: TelegramChannelFlags) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([forumPeer(flags: flags)], update: { _, new in new }); return true
    }
}

private nonisolated func forumUpdate(_ box: Postbox, thread: Int64 = 1,
    data: MessageHistoryThreadData? = nil, pinned: [Int64]? = nil,
    draft: SynchronizeableChatInputState? = nil) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let peer = forumPeer().id
        if let data { transaction.setMessageHistoryThreadInfo(peerId: peer, threadId: thread, info: forumStored(data)) }
        if let pinned { transaction.setPeerPinnedThreads(peerId: peer, threadIds: pinned) }
        if let draft { _internal_updateChatInputState(transaction: transaction, peerId: peer, threadId: thread, inputState: draft) }
        return true
    }
}

private nonisolated func forumCorrupt(_ box: Postbox, data: Data = Data([0x7b])) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.setMessageHistoryThreadInfo(peerId: forumPeer().id, threadId: 1, info:
            StoredMessageHistoryThreadInfo(data: CodableEntry(data: data), summary:
                .init(totalUnreadCount: 0, isMarkedUnread: false, mutedUntil: nil, maxOutgoingReadId: 0)))
        return true
    }
}

@MainActor final class TelegramForumTopicsTests: TelegramSourceFactsIntegrationTestCase {
    private var chat: Int64 { forumPeer().id.toInt64() }

    private func box() async throws -> Postbox {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return try await sourceFactsOpen(path)
    }

    private func read(_ box: Postbox, account: Int64 = 1, chatID: Int64? = nil)
        async throws -> Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError> {
        try await sourceFactsValue(telegramForumTopicsSignal(postbox: box, accountID: account, chatID: chatID ?? chat))
    }

    private func success(_ result: Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError>,
        file: StaticString = #filePath, line: UInt = #line) -> TelegramForumTopicsSnapshot? {
        guard case let .success(snapshot) = result else {
            XCTFail("Expected a native forum snapshot, received \(result)", file: file, line: line); return nil
        }
        return snapshot
    }

    // Merging topics by a bare thread number would mix different chats/accounts.
    func testExactForumIdentityAndGeneralTopicSurviveNativeMapping() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSeed(box))
        _ = try await sourceFactsValue(forumSeed(box, number: 43))
        guard let a = success(try await read(box)), let b = success(try await read(box, account: 2)),
            let c = success(try await read(box, chatID: forumPeer(43).id.toInt64())) else { return }
        XCTAssertEqual(a.accountID, 1); XCTAssertEqual(a.chatID, chat); XCTAssertFalse(a.isLoading)
        XCTAssertEqual(a.topics.map(\.threadID), [1]); XCTAssertEqual(a.topics.first?.title, "General")
        XCTAssertEqual(a.topics.first?.lastMessage?.actionMetadata?.threadID, 1)
        XCTAssertNotEqual(a.topics.first?.id, b.topics.first?.id)
        XCTAssertNotEqual(a.topics.first?.id, c.topics.first?.id)
    }

    // Sorting again by unread/title loses the native pin and latest-message order.
    func testNativePinnedThenLatestOrderAndUnreadFlagsArePreserved() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSeed(box, topics: [
            (1, 100, forumData(title: "A")), (2, 300, forumData(title: "B", unread: 7)),
            (3, 200, forumData(title: "C"))]))
        _ = try await sourceFactsValue(forumUpdate(box, pinned: [3, 1]))
        guard let snapshot = success(try await read(box)) else { return }
        XCTAssertEqual(snapshot.topics.map(\.threadID), [3, 1, 2])
        XCTAssertEqual(snapshot.topics.map(\.pinnedIndex), [0, 1, nil])
        XCTAssertEqual(snapshot.topics.last?.unreadCount, 7); XCTAssertEqual(snapshot.topics.last?.isMarkedUnread, true)
    }

    // A live title/closed/mute change and UTF16 draft must replace the list row.
    func testReactiveFlagsExactTitleAndThreadDraftReplaceCurrentTopic() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSeed(box))
        let title = String(repeating: "e\u{301}", count: 129)
        let initial = expectation(description: "Initial topic"), changed = expectation(description: "Changed topic")
        var result: TelegramForumTopicsSnapshot?
        let operation = telegramForumTopicsSignal(postbox: box, accountID: 1, chatID: chat).start(next: { value in
            MainActor.assumeIsolated {
                guard case let .success(snapshot) = value else { return }
                if snapshot.topics.first?.title == "General" { initial.fulfill() }
                if snapshot.topics.first?.draft?.text == "😀 remote" { result = snapshot; changed.fulfill() }
            }
        })
        defer { operation.dispose() }
        await fulfillment(of: [initial], timeout: 2)
        let native = SynchronizeableChatInputState(replySubject: nil, text: "😀 remote",
            entities: [.init(range: 0..<2, type: .Bold)], timestamp: 101, textSelection: nil,
            messageEffectId: nil, suggestedPost: nil)
        _ = try await sourceFactsValue(forumUpdate(box,
            data: forumData(title: title, unread: 5, closed: true, hidden: true, owned: true, mute: .muted(until: Int32.max)),
            draft: native))
        await fulfillment(of: [changed], timeout: 2)
        guard let row = result?.topics.first else { return }
        XCTAssertEqual(Array(row.title.utf8), Array(title.utf8))
        XCTAssertTrue(row.isClosed); XCTAssertTrue(row.isHidden); XCTAssertTrue(row.isOwnedByMe); XCTAssertTrue(row.isMuted)
        XCTAssertEqual(row.iconFileID, 99); XCTAssertEqual(row.iconColor, 0x6fb9f0)
        XCTAssertEqual(row.draft?.entities, [.init(offset: 0, length: 2, kind: .bold)])
    }

    // The thread-index view's cached peer alone misses a pure peer conversion.
    func testCurrentPeerConversionRejectsFormerForumWithoutThreadMutation() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSeed(box))
        let first = expectation(description: "Initial forum"), rejected = expectation(description: "Converted peer")
        let operation = telegramForumTopicsSignal(postbox: box, accountID: 1, chatID: chat).start(next: { value in
            switch value { case .success: first.fulfill(); case .failure(.incompatible): rejected.fulfill(); default: break }
        })
        defer { operation.dispose() }
        await fulfillment(of: [first], timeout: 2)
        _ = try await sourceFactsValue(forumChangePeer(box, flags: []))
        await fulfillment(of: [rejected], timeout: 2)
    }

    // A monoforum carries per-person paid threads, not ordinary forum topics.
    func testMonoforumAndNonChannelCannotEnterForumTopics() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSeed(box, flags: [.isForum, .isMonoforum]))
        let monoforum = try await read(box)
        XCTAssertEqual(monoforum, .failure(.incompatible))
        let user = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42)).toInt64()
        let nonChannel = try await read(box, chatID: user)
        XCTAssertEqual(nonChannel, .failure(.incompatible))
    }

    // No index boundary means loading, not an authoritative empty topic list.
    func testInitialNativeHoleRemainsLoadingUntilLoadedBoundaryArrives() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSeed(box, loaded: false))
        guard let loading = success(try await read(box)) else { return }
        XCTAssertTrue(loading.isLoading); XCTAssertEqual(loading.topics, [])
        _ = try await sourceFactsValue(forumSeed(box))
        guard let ready = success(try await read(box)) else { return }
        XCTAssertFalse(ready.isLoading); XCTAssertEqual(ready.topics.map(\.threadID), [1])
    }

    // API topic ids are signed Int32; silently clamping aliases a different topic.
    func testOutOfRangeNativeTopicIDAndNegativeUnreadFailClosed() async throws {
        for (thread, unread) in [(Int64(Int32.max) + 1, Int32(0)), (Int64(1), Int32(-1))] {
            let box = try await box()
            _ = try await sourceFactsValue(forumSeed(box, topics: [(thread, 100, forumData(unread: unread))]))
            let result = try await read(box)
            XCTAssertEqual(result, .failure(.incompatible))
        }
    }

    // A corrupt native topic must not be silently dropped from an apparently complete list.
    func testMalformedNativeTopicFailsWithoutPartialList() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSeed(box))
        _ = try await sourceFactsValue(forumCorrupt(box))
        let result = try await read(box)
        XCTAssertEqual(result, .failure(.incompatible))
    }

    // An invalid value tag must be rejected before Postbox's unchecked legacy reader.
    func testInvalidNativeTopicWireTypeNeverEntersDecoder() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(forumSeed(box))
        _ = try await sourceFactsValue(forumCorrupt(box, data: Data([1, 0x5f, 0x7f])))
        let result = try await read(box)
        XCTAssertEqual(result, .failure(.incompatible))
    }

    // Removing structural validation lets truncated nested objects reach unsafe native reads.
    func testTopicDecodeRejectsEveryTruncatedPrefixAndMalformedStructure() throws {
        let entry = try XCTUnwrap(CodableEntry(forumData(title: "Exact 😀 topic")))
        XCTAssertEqual(telegramForumTopicData(entry)?.info.title, "Exact 😀 topic")
        for count in 0..<entry.data.count {
            XCTAssertNil(telegramForumTopicData(CodableEntry(data: Data(entry.data.prefix(count)))), "Prefix \(count)")
        }
        for bytes: [UInt8] in [[0x7b], [1, 0x5f, 0x7f], [1, 0x5f, 5, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0x7f],
            [1, 0x5f, 5, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0x61, 0x7f],
            [1, 0x5f, 4, 1, 0, 0, 0, 0xff]] {
            XCTAssertNil(telegramForumTopicData(CodableEntry(data: Data(bytes))))
        }
    }

    // Structurally valid but unknown notification variants must not trigger native assertions.
    func testTopicDecodeRejectsInvalidNotificationVariants() throws {
        let original = try XCTUnwrap(CodableEntry(forumData())).data
        for key in ["m.v", "p.v", "s.v"] {
            let marker = Data([3] + Array(key.utf8) + [0])
            let span = try XCTUnwrap(original.range(of: marker))
            var bytes = original
            bytes.replaceSubrange(span.upperBound..<(span.upperBound + 4), with: [99, 0, 0, 0])
            XCTAssertNil(telegramForumTopicData(CodableEntry(data: bytes)), key)
        }
    }

    // Legacy bundled sound ids are offset with checked Int32 arithmetic by the native model.
    func testTopicDecodeRejectsBundledSoundIDOverflow() throws {
        for (sound, maximum) in [(PeerMessageSound.bundledModern(id: 1), Int32.max - 100),
                                 (.bundledClassic(id: 1), Int32.max - 2)] {
            let original = try XCTUnwrap(CodableEntry(forumData(sound: sound))).data
            let span = try XCTUnwrap(original.range(of: Data([3] + Array("s.i".utf8) + [0])))
            var bytes = original
            var bad = Int32.max.littleEndian
            withUnsafeBytes(of: &bad) { bytes.replaceSubrange(span.upperBound..<(span.upperBound + 4), with: $0) }
            XCTAssertNil(telegramForumTopicData(CodableEntry(data: bytes)))
            var good = maximum.littleEndian
            withUnsafeBytes(of: &good) { bytes.replaceSubrange(span.upperBound..<(span.upperBound + 4), with: $0) }
            XCTAssertNotNil(telegramForumTopicData(CodableEntry(data: bytes)))
        }
    }

    // The pinned native PeerId decoder asserts on noncanonical high bits.
    func testTopicDecodeRejectsNoncanonicalAuthorBits() throws {
        let original = try XCTUnwrap(CodableEntry(forumData())).data
        let span = try XCTUnwrap(original.range(of: Data([2] + Array("iv".utf8) + [1])))
        for value in [Int64.max, Int64.min, -1] {
            var bytes = original, bad = value.littleEndian
            withUnsafeBytes(of: &bad) { bytes.replaceSubrange(span.upperBound..<(span.upperBound + 8), with: $0) }
            XCTAssertNil(telegramForumTopicData(CodableEntry(data: bytes)))
        }
    }

    private func snapshot(account: Int64 = 1, number: Int64 = 42, thread: Int64 = 1) -> TelegramForumTopicsSnapshot {
        let peer = forumPeer(number).id.toInt64()
        return .init(accountID: account, chatID: peer, topics: [
            .init(accountID: account, chatID: peer, threadID: thread, title: "Synthetic")], isLoading: false)
    }

    // Hiding/rebinding cancels an active list; late callbacks may not restore it.
    func testControllerVisibilityRebindingAndOldCallbacksCannotPublish() {
        let controller = TelegramForumTopicsController()
        var callbacks: [(Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError>) -> Void] = []
        controller.bind(accountID: 1) { _ in Signal { subscriber in
            callbacks.append { subscriber.putNext($0) }; return EmptyDisposable
        } }
        controller.selectChat(chat); XCTAssertEqual(controller.phase, .idle)
        controller.setVisible(true); XCTAssertEqual(controller.phase, .loading)
        guard callbacks.count == 1 else { XCTFail("Visible forum did not subscribe"); return }
        callbacks[0](.success(snapshot())); XCTAssertEqual(controller.snapshot?.topics.first?.threadID, 1)
        controller.selectChat(forumPeer(43).id.toInt64()); XCTAssertNil(controller.snapshot)
        callbacks[0](.success(snapshot())); XCTAssertNil(controller.snapshot)
        guard callbacks.count == 2 else { XCTFail("New forum did not subscribe"); return }
        callbacks[1](.success(snapshot(number: 43))); XCTAssertEqual(controller.snapshot?.chatID, forumPeer(43).id.toInt64())
        controller.setVisible(false); XCTAssertNil(controller.snapshot); XCTAssertEqual(controller.phase, .idle)
        callbacks[1](.success(snapshot(number: 43))); XCTAssertNil(controller.snapshot)
        controller.setVisible(true)
        controller.bind(accountID: 2) { _ in .single(.success(self.snapshot(account: 2, number: 43))) }
        XCTAssertEqual(controller.snapshot?.accountID, 2)
        callbacks[1](.success(snapshot(number: 43))); XCTAssertEqual(controller.snapshot?.accountID, 2)
    }

    // Even an injected provider cannot smuggle another account/chat/topic identity.
    func testControllerRejectsForeignOrDuplicateTopicIdentityAndRecovers() {
        let pipe = ValuePipe<Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError>>()
        let controller = TelegramForumTopicsController()
        controller.bind(accountID: 1) { _ in pipe.signal() }; controller.selectChat(chat); controller.setVisible(true)
        pipe.putNext(.success(snapshot(account: 2))); XCTAssertNil(controller.snapshot)
        pipe.putNext(.success(snapshot(number: 43))); XCTAssertNil(controller.snapshot)
        let row = snapshot().topics[0]
        let foreign = snapshot(number: 43).topics[0]
        pipe.putNext(.success(.init(accountID: 1, chatID: chat, topics: [foreign], isLoading: false)))
        XCTAssertNil(controller.snapshot); XCTAssertEqual(controller.phase, .failed(.incompatible))
        pipe.putNext(.success(.init(accountID: 1, chatID: chat, topics: [row, row], isLoading: false)))
        XCTAssertNil(controller.snapshot); XCTAssertEqual(controller.phase, .failed(.incompatible))
        pipe.putNext(.success(snapshot())); XCTAssertEqual(controller.snapshot?.topics.count, 1)
        XCTAssertEqual(controller.phase, .ready)
    }

    // An empty loading source cannot leave stale rows indefinitely after navigation.
    func testControllerDeadlineFailsClosedAndLateSnapshotCannotReviveRequest() async {
        let pipe = ValuePipe<Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError>>()
        let controller = TelegramForumTopicsController(timeout: .milliseconds(20))
        controller.bind(accountID: 1) { _ in pipe.signal() }; controller.selectChat(chat); controller.setVisible(true)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.phase, .failed(.unavailable)); XCTAssertNil(controller.snapshot)
        pipe.putNext(.success(snapshot())); XCTAssertNil(controller.snapshot)
    }
}

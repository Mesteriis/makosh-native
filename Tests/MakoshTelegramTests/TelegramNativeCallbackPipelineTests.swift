import XCTest
import Combine
import TelegramCore
import TelegramApi
@testable import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramNativeCallbackPipelineTests: XCTestCase {
    func testNativeDateLookupHandlesMissingCachedPeer() async throws {
        let account = try await telegramCallbackAccount(test: self)
        let search = TelegramSearchModel()
        search.bind(account: account); search.selectChat(777)
        let failed = expectation(description: "Missing date result")
        let observation = search.$dateStatus.filter { $0 == .failed }.prefix(1).sink { _ in failed.fulfill() }
        defer { observation.cancel(); search.bind(account: nil) }
        search.jumpToDate(Date(timeIntervalSince1970: 1000))
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertEqual(search.dateStatus, .failed)
    }

    func testNativeChatSearchBuildsPresenceViewAndServerOffsetOffMain() async throws {
        let account = try await telegramCallbackAccount(test: self)
        _ = try await telegramDataValue(callbackSeedMessage(account.postbox), test: self)
        let search = TelegramSearchModel()
        search.setRemoteDiscoveryEnabled(false); search.bind(account: account)
        let ready = expectation(description: "Native local chat and presence")
        let observation = search.$chatStatus.filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        defer { observation.cancel(); search.bind(account: nil) }
        search.chatQuery = "Synthetic Callback"
        await fulfillment(of: [ready], timeout: 10)
        let chat = try XCTUnwrap(search.chats.first(where: { $0.id == 777 }))
        XCTAssertEqual(chat.preview, "before")
        XCTAssertEqual(chat.presence?.accountID, 123)
        XCTAssertEqual(chat.presence?.peerID, 777)
    }

    func testNativeSenderCandidatesCombineMembersAndHistoryOnNativeQueues() async throws {
        let account = try await telegramCallbackAccount(test: self)
        _ = try await telegramDataValue(callbackSeedMessage(account.postbox), test: self)
        let senders = TelegramSearchSenders()
        let available = expectation(description: "Native sender group")
        let membership = senders.$available.filter { $0 }.prefix(1).sink { _ in available.fulfill() }
        defer { membership.cancel(); senders.bind(account: nil, chatID: nil, threadID: nil) }
        senders.bind(account: account, chatID: callbackGroupID.toInt64(), threadID: nil)
        await fulfillment(of: [available], timeout: 10)
        let ready = expectation(description: "Native combined sender suggestions")
        let result = senders.$status.filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        defer { result.cancel() }
        senders.retry()
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(senders.candidates.first?.id, 123)
        XCTAssertEqual(Set(senders.candidates.map(\.id)).count, senders.candidates.count)
    }

    func testNativeReplyAndForwardAdmissionsRevalidateTheirSourcesAtCommit() async throws {
        let account = try await telegramCallbackAccount(test: self)
        _ = try await telegramDataValue(callbackSeedMessage(account.postbox), test: self)
        let committed = try await telegramDataValue(callbackMessageSource(account.postbox), test: self)
        let source = try XCTUnwrap(committed)
        let valid = try await telegramDataValue(callbackAdmissions(account.postbox, source: source), test: self)
        XCTAssertTrue(valid.reply); XCTAssertTrue(valid.forward)
        _ = try await telegramDataValue(callbackSeedMessage(account.postbox, text: "changed", update: true), test: self)
        let stale = try await telegramDataValue(callbackAdmissions(account.postbox, source: source), test: self)
        XCTAssertFalse(stale.reply); XCTAssertFalse(stale.forward)
    }

    func testNativeEditMissingInputPeerReconcilesWithoutNetworkOrActorViolation() async throws {
        let account = try await telegramCallbackAccount(test: self)
        _ = try await telegramDataValue(callbackSeedMessage(account.postbox), test: self)
        let committed = try await telegramDataValue(callbackMessageSource(account.postbox), test: self)
        let source = try XCTUnwrap(committed)
        let provider = TelegramEngineMessageActionsProvider(account: account, approval: TelegramSendApprovalController())
        let reconciled = expectation(description: "Unchanged edit reconciled")
        let lease = provider.start(action: .edit("after"), source: source) { event in
            switch event {
            case .committing: break
            case .uncertain: reconciled.fulfill()
            default: XCTFail("Missing native input peer was accepted as an applied edit"); reconciled.fulfill()
            }
        }
        defer { lease.cancel() }
        await fulfillment(of: [reconciled], timeout: 10)
    }

    func testNativeSecretTTLCommitsOnPostboxAndRejectsCancelledAdmission() async throws {
        let account = try await telegramCallbackAccount(test: self)
        _ = try await telegramDataValue(callbackSeedSecret(account.postbox), test: self)
        let first = try await telegramDataValue(telegramNativeSecretSession(account: account, chatID: callbackSecretID.toInt64()), test: self)
        let basis = try XCTUnwrap(first)
        XCTAssertTrue(basis.canSetTTL)
        let denied = try await telegramDataValue(telegramEnqueueNativeSecretTTL(account: account, basis: basis,
            timeout: 60, admitted: Atomic(value: false)), test: self)
        XCTAssertNil(denied)
        let unchanged = try await telegramDataValue(telegramNativeSecretSession(account: account, chatID: basis.chatID), test: self)
        XCTAssertEqual(unchanged, basis)
        let provider = TelegramEngineSecretChatProvider(account: account)
        let queued = expectation(description: "Native secret TTL receipt")
        var committing = false
        let request = provider.setTTL(basis: basis, timeout: 60) { event in
            switch event {
            case .committing: committing = true
            case let .queued(receipt): XCTAssertEqual(receipt.timeout, 60); queued.fulfill()
            case let .failed(error): XCTFail("Native TTL rejected: \(error)"); queued.fulfill()
            }
            return true
        }
        defer { request.cancel() }
        await fulfillment(of: [queued], timeout: 10)
        XCTAssertTrue(committing)
        let current = try await telegramDataValue(telegramNativeSecretSession(account: account, chatID: basis.chatID), test: self)
        XCTAssertEqual(current?.ttl, 60)
        XCTAssertNotEqual(current?.revision, basis.revision)
    }

    func testCreatedSecretSessionMapsBackgroundErrorsAndNestedPostboxSnapshot() async throws {
        let account = try await telegramCallbackAccount(test: self)
        _ = try await telegramDataValue(callbackSeedSecret(account.postbox), test: self)
        let success = expectation(description: "Created secret snapshot")
        let subscription = (telegramCreatedSecretSession(account: account, creation: callbackSecretCreation(.success(callbackSecretID)))
            |> deliverOnMainQueue).start(next: { value in
                XCTAssertEqual(value.chatID, callbackSecretID.toInt64()); success.fulfill()
            }, error: { error in XCTFail("Synthetic creation failed: \(error)"); success.fulfill() })
        defer { subscription.dispose() }
        await fulfillment(of: [success], timeout: 10)
        for error in [CreateSecretChatError.generic, .limitExceeded, .premiumRequired(EnginePeer(callbackUser(777)))] {
            let failed = expectation(description: "Secret creation error mapping")
            let subscription = (telegramCreatedSecretSession(account: account, creation: callbackSecretCreation(.failure(error)))
                |> deliverOnMainQueue).start(error: { value in
                    switch error {
                    case .generic: XCTAssertEqual(value, .uncertain)
                    case .limitExceeded: XCTAssertEqual(value, .limitExceeded)
                    case .premiumRequired: XCTAssertEqual(value, .premiumRequired)
                    }
                    failed.fulfill()
                })
            await fulfillment(of: [failed], timeout: 10)
            subscription.dispose()
        }
    }

    func testNativeGroupPageCompositionAcceptsBackgroundBasisWithoutNetwork() async throws {
        let account = try await telegramCallbackAccount(test: self)
        let received = expectation(description: "Native overview page")
        let subscription = (telegramNativeGroupPageSignal(account: account, basis: try callbackGroupBasis(),
            page: .overview, ownerID: nil, query: "", cursor: nil, historyFilter: .all)
            |> deliverOnMainQueue).start(next: { value in
                XCTAssertEqual(value.snapshot.accountID, 123)
                XCTAssertEqual(value.snapshot.title, "Synthetic group"); received.fulfill()
            }, error: { error in XCTFail("Synthetic group overview failed: \(error)"); received.fulfill() })
        defer { subscription.dispose() }
        await fulfillment(of: [received], timeout: 10)
    }
}

private nonisolated var callbackGroupID: PeerId { .init(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(10)) }
private nonisolated var callbackSecretID: PeerId { .init(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(44)) }
private nonisolated func callbackUser(_ number: Int64) -> TelegramUser {
    .init(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(number)), accessHash: nil,
        firstName: number == 123 ? "Synthetic Own" : "Synthetic Callback", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
nonisolated func callbackSeedMessage(_ box: Postbox, text: String = "before", update: Bool = false) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let own = callbackUser(123), user = callbackUser(777)
        let group = TelegramGroup(id: callbackGroupID, title: "Synthetic group", photo: [], participantCount: 2,
            role: .creator(rank: nil), membership: .Member, flags: [], defaultBannedRights: nil,
            migrationReference: nil, creationDate: 0, version: 1)
        transaction.updatePeersInternal([own, user, group], update: { _, value in value })
        transaction.updatePeerCachedData(peerIds: [user.id], update: { _, _ in CachedUserData() })
        transaction.updatePeerPresencesInternal(presences: [user.id: TelegramUserPresence(status: .present(until: Int32.max), lastActivity: 0)], merge: { _, value in value })
        let id = MessageId(peerId: user.id, namespace: Namespaces.Message.Cloud, id: 1)
        let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: Int32(Date().timeIntervalSince1970) - 1, flags: [], tags: [], globalTags: [], localTags: [],
            forwardInfo: nil, authorId: own.id, text: text, attributes: [], media: [])
        if update { transaction.updateMessage(id) { _ in .update(message) } }
        else { _ = transaction.addMessages([message], location: .Random) }
        transaction.updatePeerChatListInclusion(user.id, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
    }
}
private nonisolated func callbackMessageSource(_ box: Postbox) -> Signal<TelegramMessageActionSource?, NoError> {
    box.transaction { transaction in
        transaction.getMessage(MessageId(peerId: PeerId(777), namespace: Namespaces.Message.Cloud, id: 1))
            .map { telegramMessageActionSource($0, accountID: 123, chatID: 777) }
    }
}
private nonisolated func callbackAdmissions(_ box: Postbox, source: TelegramMessageActionSource) -> Signal<(reply: Bool, forward: Bool), NoError> {
    let reply = telegramReplyAdmission(accountID: 123, source: source, formatted: try! TelegramFormattedText(text: "after"))
    let forward = telegramForwardAdmission(accountID: 123, source: source)
    return box.transaction { (reply($0), forward($0)) }
}
private nonisolated func callbackSeedSecret(_ box: Postbox) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let own = callbackUser(123), regular = callbackUser(777)
        let peer = TelegramSecretChat(id: callbackSecretID, creationDate: 1000, regularPeerId: regular.id, accessHash: 88,
            role: .creator, embeddedState: .active, messageAutoremoveTimeout: nil)
        let sequence = SecretChatSequenceBasedLayerState(layerNegotiationState: .init(activeLayer: .layer144, locallyRequestedLayer: 144, remotelyRequestedLayer: 144),
            rekeyState: nil, baseIncomingOperationIndex: 0, baseOutgoingOperationIndex: 0, topProcessedCanonicalIncomingOperationIndex: nil)
        let state = SecretChatState(role: .creator, embeddedState: .sequenceBasedLayer(sequence),
            keychain: .init(keys: [.init(fingerprint: 1, key: MemoryBuffer(data: Data(repeating: 0x5a, count: 256)), validity: .indefinite, useCount: 0)]),
            keyFingerprint: .init(sha1: .init(digest: Data(0..<20)), sha256: .init(digest: Data(32..<64))), messageAutoremoveTimeout: nil)
        transaction.updatePeersInternal([own, regular, peer], update: { _, value in value })
        transaction.setPeerChatState(callbackSecretID, state: state)
    }
}
private enum CallbackSecretCreation { case success(PeerId), failure(CreateSecretChatError) }
private nonisolated func callbackSecretCreation(_ result: CallbackSecretCreation) -> Signal<PeerId, CreateSecretChatError> {
    let signal: Signal<PeerId, CreateSecretChatError>
    switch result { case let .success(id): signal = .single(id); case let .failure(error): signal = .fail(error) }
    return signal |> deliverOn(Queue(name: "Makosh.callback.fixture", qos: .default))
}
private nonisolated func callbackGroupBasis() throws -> Signal<TelegramNativeGroupBasis, TelegramGroupMembershipError> {
    let chat = Api.Chat.chat(flags: 1, id: 10, title: "Synthetic group", photo: .chatPhotoEmpty,
        participantsCount: 2, date: 1, version: 1, migratedTo: nil, adminRights: nil, defaultBannedRights: nil)
    let full = Api.ChatFull.chatFull(flags: 0, id: 10, about: "", participants: .chatParticipantsForbidden(flags: 0, chatId: 10, selfParticipant: nil),
        chatPhoto: nil, notifySettings: .peerNotifySettings(flags: 0, showPreviews: nil, silent: nil, muteUntil: nil,
            iosSound: nil, androidSound: nil, otherSound: nil, storiesMuted: nil, storiesHideSender: nil,
            storiesIosSound: nil, storiesAndroidSound: nil, storiesOtherSound: nil),
        exportedInvite: nil, botInfo: nil, pinnedMsgId: nil, folderId: nil, call: nil, ttlPeriod: nil,
        groupcallDefaultJoinAs: nil, themeEmoticon: nil, requestsPending: nil, recentRequesters: nil, availableReactions: nil, reactionsLimit: nil)
    let value = try XCTUnwrap(makoshGroupFullPeer(.chatFull(fullChat: full, chats: [chat], users: []), peerId: callbackGroupID))
    let snapshot = try XCTUnwrap(telegramGroupMembershipSnapshot(peer: value.peer, accountID: 123))
    let input = try XCTUnwrap(telegramGroupInputPeer(value.peer))
    return Signal<TelegramNativeGroupBasis, TelegramGroupMembershipError>.single(.init(full: value, snapshot: snapshot, input: input))
        |> deliverOn(Queue(name: "Makosh.callback.fixture", qos: .default))
}

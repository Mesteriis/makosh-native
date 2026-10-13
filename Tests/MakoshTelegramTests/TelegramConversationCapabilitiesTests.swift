import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func specialUser(_ number: Int64 = 42, flags: UserInfoFlags = []) -> TelegramUser {
    TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(number)),
        accessHash: nil, firstName: "Synthetic", lastName: "Participant", username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: flags, emojiStatus: nil, usernames: [],
        storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
        profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}

private nonisolated func specialChannel(fee: StarsAmount? = nil, flags: TelegramChannelFlags = [],
    admin: Bool = false) -> TelegramChannel {
    TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(43)),
        accessHash: nil, title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
        participationStatus: .member, info: .group(.init(flags: [])), flags: flags,
        restrictionInfo: nil, adminRights: admin ? TelegramChatAdminRights(rights: [.canDeleteMessages]) : nil,
        bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil,
        backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil,
        approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil,
        sendPaidMessageStars: fee, linkedMonoforumId: nil)
}

private nonisolated func specialSecret(_ state: SecretChatEmbeddedPeerState = .active, number: Int64 = 44) -> TelegramSecretChat {
    TelegramSecretChat(id: PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(number)),
        creationDate: 1, regularPeerId: specialUser().id, accessHash: 0, role: .creator,
        embeddedState: state, messageAutoremoveTimeout: nil)
}

private nonisolated func specialSecretState(_ state: SecretChatEmbeddedState = .basicLayer,
    keyBytes: Int = 256, fingerprint: Bool = true, variant: UInt8 = 0) -> SecretChatState {
    // Synthetic public fingerprint and throwaway key material only; never an account key.
    let sha1 = Data((0..<20).map { UInt8($0) &+ variant })
    let sha256 = Data((32..<64).map { UInt8($0) &+ variant })
    return SecretChatState(role: .creator, embeddedState: state,
        keychain: SecretChatKeychain(keys: keyBytes == 0 ? [] : [SecretChatKey(fingerprint: 1,
            key: MemoryBuffer(data: Data(repeating: 0x5a, count: keyBytes)), validity: .indefinite, useCount: 0)]),
        keyFingerprint: fingerprint ? .init(sha1: .init(digest: sha1), sha256: .init(digest: sha256)) : nil,
        messageAutoremoveTimeout: nil)
}

private nonisolated func specialAllowed(_ box: Postbox, context: TelegramSendContext,
    messages: [EnqueueMessage], consentID: UUID? = nil) -> Signal<Bool, NoError> {
    box.transaction { telegramSendAuthorization(transaction: $0, context: context, messages: messages, consentID: consentID) }
}
private nonisolated func specialReadSecretSession(_ box: Postbox, chatID: Int64) -> Signal<TelegramSecretSessionSnapshot?, NoError> {
    box.transaction { telegramSecretSessionSnapshot(transaction: $0, accountID: 1, chatID: chatID) }
}

private nonisolated func specialCreate(_ box: Postbox, context: TelegramSendContext,
    price: Int64 = 7, id: UUID) -> Signal<Result<TelegramPaidSendConsent, Error>, NoError> {
    box.transaction { transaction in
        Result { try telegramPaidSendConsentCreate(transaction: transaction, context: context, perMessageStars: price, consentID: id) }
    }
}

private nonisolated func specialRead(_ box: Postbox, context: TelegramSendContext,
    id: UUID) -> Signal<Result<TelegramPaidSendConsentRecord?, Error>, NoError> {
    box.transaction { transaction in Result { try telegramPaidSendConsentRead(transaction: transaction, context: context, consentID: id) } }
}

private nonisolated func specialBegin(_ box: Postbox, context: TelegramSendContext,
    id: UUID) -> Signal<Result<Void, Error>, NoError> {
    box.transaction { transaction in Result { try telegramPaidSendConsentBegin(transaction: transaction, context: context, consentID: id) } }
}

private nonisolated func specialConsume(_ box: Postbox, context: TelegramSendContext,
    id: UUID, ids: [MessageId?]) -> Signal<Result<Void, Error>, NoError> {
    box.transaction { transaction in
        Result { try telegramPaidSendConsentConsume(transaction: transaction, context: context, consentID: id, messageIDs: ids) }
    }
}

private nonisolated func specialState(_ box: Postbox, variant: UInt8) -> Signal<Void, NoError> {
    box.transaction { $0.setPeerChatState(specialSecret().id, state: specialSecretState(variant: variant)) }
}

private nonisolated func specialRaw(_ box: Postbox, context: TelegramSendContext,
    id: UUID) -> Signal<Data?, NoError> {
    box.transaction { $0.getPreferencesEntry(key: telegramPaidSendConsentKey(context: context, consentID: id))?.data }
}

private nonisolated func specialCorrupt(_ box: Postbox, context: TelegramSendContext,
    id: UUID, bytes: Data) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.setPreferencesEntry(key: telegramPaidSendConsentKey(context: context, consentID: id), value: .init(data: bytes))
        return true
    }
}

private nonisolated func specialEnqueue(_ box: Postbox, context: TelegramSendContext,
    messages: [EnqueueMessage], consentID: UUID? = nil) -> Signal<[MessageId?], NoError> {
    enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(context.accountID), isSupportUser: false,
        timestamp: 100, peerId: PeerId(context.chatID), messages: messages,
        transactionAdmission: { transaction in
            guard telegramSendAuthorization(transaction: transaction, context: context, messages: messages, consentID: consentID) else { return false }
            if let consentID {
                do { try telegramPaidSendConsentBegin(transaction: transaction, context: context, consentID: consentID) }
                catch { return false }
            }
            return true
        }, transactionCommit: { transaction, ids in
            if let consentID {
                try? telegramPaidSendConsentConsume(transaction: transaction, context: context, consentID: consentID, messageIDs: ids)
            }
        })
}

private nonisolated func specialAuthorizedEnqueue(_ box: Postbox, context: TelegramSendContext,
    messages: [EnqueueMessage], consent: TelegramPaidSendConsent,
    specificAdmission: Bool = true) -> Signal<[MessageId?], NoError> {
    let receipt = TelegramSendAuthorizationReceipt(context: context, consent: consent)
    return enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(context.accountID), isSupportUser: false,
        timestamp: 100, peerId: PeerId(context.chatID), messages: messages,
        transactionAdmission: receipt.admission(messages: messages, specificAdmission: { _ in specificAdmission }),
        transactionCommit: { transaction, ids in _ = receipt.acknowledge(transaction: transaction, messageIDs: ids) })
}

// Unconditional local insertion is only a fixture for validating the durable
// receipt boundary; it constructs no Account and cannot contact Telegram.
private nonisolated func specialReceiptFixture(_ box: Postbox, account: Int64 = 1,
    chat: PeerId = specialUser().id, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {
    enqueueMessagesLocally(postbox: box, accountPeerId: PeerId(account), isSupportUser: false,
        timestamp: 100, peerId: chat, messages: messages)
}

private nonisolated func specialSeed(_ box: Postbox, peer: Peer = specialUser(),
    cache: CachedPeerData? = CachedUserData(), state: SecretChatState? = nil) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal([specialUser(1), specialUser(), peer], update: { _, new in new })
        transaction.updatePeerCachedData(peerIds: [peer.id], update: { _, _ in cache })
        if let state { transaction.setPeerChatState(peer.id, state: state) }
        return true
    }
}

private nonisolated func specialMessage(stars: Int64? = nil, duplicate: Bool = false,
    postpone: Bool = false, thread: Int64? = nil, reply: Bool = false,
    media: Bool = false) -> EnqueueMessage {
    var attributes: [MessageAttribute] = []
    if let stars {
        attributes.append(PaidStarsMessageAttribute(stars: .init(value: stars, nanos: 0), postponeSending: postpone))
        if duplicate { attributes.append(PaidStarsMessageAttribute(stars: .init(value: stars, nanos: 0), postponeSending: false)) }
    }
    let image = TelegramMediaImage(imageId: .init(namespace: Namespaces.Media.LocalImage, id: 1),
        representations: [], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    return .message(text: "Synthetic plaintext 😀", attributes: attributes, inlineStickers: [:],
        mediaReference: media ? .standalone(media: image) : nil, threadId: thread,
        replyToMessageId: reply ? .init(messageId: .init(peerId: specialSecret().id,
            namespace: Namespaces.Message.SecretIncoming, id: 1), quote: nil, todoItemId: nil) : nil,
        replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
}

private nonisolated func specialContext(chat: Int64 = specialUser().id.toInt64(), account: Int64 = 1,
    revision: UUID = UUID(), count: Int = 1, thread: Int64? = nil) -> TelegramSendContext {
    .init(accountID: account, chatID: chat, threadID: thread, submissionRevision: revision, messageCount: count)
}

@MainActor final class TelegramConversationCapabilitiesTests: TelegramSourceFactsIntegrationTestCase {
    func testNegativeNativeSecretIDSupportsCapabilitiesAndPlainSend() async throws {
        let box = try await box(), peer = specialSecret(number: -44)
        _ = try await sourceFactsValue(specialSeed(box, peer: peer, cache: nil, state: specialSecretState()))
        let capabilities = try await read(box, chat: peer.id.toInt64())
        XCTAssertEqual(snapshot(capabilities)?.secret?.state, .active)
        let allowed = try await sourceFactsValue(specialAllowed(box, context: specialContext(chat: peer.id.toInt64()), messages: [specialMessage()]))
        XCTAssertTrue(allowed)
    }
    func testNativeSecretSessionFreezesLifecycleLayerTimerAndRevision() async throws {
        let box = try await box(), peer = specialSecret(number: -44)
        _ = try await sourceFactsValue(specialSeed(box, peer: peer, cache: nil, state: specialSecretState()))
        let value = try await sourceFactsValue(specialReadSecretSession(box, chatID: peer.id.toInt64()))
        let session = try XCTUnwrap(value)
        XCTAssertTrue(session.isValid); XCTAssertTrue(session.canSetTTL); XCTAssertEqual(session.layer, 8)
        XCTAssertEqual(session.regularPeerID, 42); XCTAssertNil(session.ttl); XCTAssertEqual(session.revision.count, 64)
        _ = try await sourceFactsValue(specialState(box, variant: 1))
        // The variant helper updates +44; a different native session must not change this session's frozen basis.
        let unchanged = try await sourceFactsValue(specialReadSecretSession(box, chatID: peer.id.toInt64()))
        XCTAssertEqual(unchanged, session)
    }
    func testNativeSessionCannotAuthorizeMalformedKeyOrMismatchedRole() async throws {
        let box = try await box(), peer = specialSecret()
        _ = try await sourceFactsValue(specialSeed(box, peer: peer, cache: nil, state: specialSecretState(keyBytes: 255)))
        let value = try await sourceFactsValue(specialReadSecretSession(box, chatID: peer.id.toInt64()))
        XCTAssertEqual(value?.state, .active); XCTAssertFalse(value?.canSetTTL ?? true)
        _ = try await sourceFactsValue(specialSeed(box, peer: peer, cache: nil, state: specialSecretState(.terminated)))
        let inconsistent = try await sourceFactsValue(specialReadSecretSession(box, chatID: peer.id.toInt64()))
        XCTAssertNil(inconsistent)
    }
    private func box() async throws -> Postbox {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return try await sourceFactsOpen(path)
    }

    private func read(_ box: Postbox, chat: Int64 = specialUser().id.toInt64()) async throws
        -> Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError> {
        try await sourceFactsValue(telegramConversationCapabilitiesSignal(postbox: box, accountID: 1, chatID: chat))
    }

    private func snapshot(_ result: Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>,
        file: StaticString = #filePath, line: UInt = #line) -> TelegramConversationCapabilities? {
        guard case let .success(value) = result else {
            XCTFail("Expected current native conversation capabilities, received \(result)", file: file, line: line); return nil
        }
        return value
    }

    // Silently treating missing cache/requireStars as free would bypass the prompt.
    func testUserFeeRequiresKnownCacheAndPreservesExplicitZeroAndPrice() async throws {
        let box = try await box()
        let cases: [(CachedPeerData?, UserInfoFlags, TelegramMessageFee)] = [
            (nil, [], .unavailable), (CachedUserData(), [], .free),
            (CachedUserData(), [.requireStars], .unavailable),
            (CachedUserData().withUpdatedSendPaidMessageStars(.zero), [.requireStars], .free),
            (CachedUserData().withUpdatedSendPaidMessageStars(.init(value: 7, nanos: 0)), [], .stars(7))]
        for (cache, flags, expected) in cases {
            _ = try await sourceFactsValue(specialSeed(box, peer: specialUser(flags: flags), cache: cache))
            guard let current = snapshot(try await read(box)) else { continue }
            XCTAssertEqual(current.messageFee, expected); XCTAssertNil(current.secret)
            XCTAssertEqual(current.accountID, 1); XCTAssertEqual(current.chatID, specialUser().id.toInt64())
        }
    }

    // Saved Messages uses the exact trusted account identity even without a fee cache;
    // foreign unknown users still require refreshed capabilities before insertion.
    func testSavedMessagesWithoutCacheRemainsFreeWhileForeignUnknownUserCannotQueue() async throws {
        let box = try await box(), ownChat = specialUser(1).id.toInt64()
        _ = try await sourceFactsValue(specialSeed(box, peer: specialUser(1), cache: nil))
        guard let own = snapshot(try await read(box, chat: ownChat)) else { return }
        XCTAssertEqual(own.messageFee, .free)
        let ownIDs = try await sourceFactsValue(specialEnqueue(box, context: specialContext(chat: ownChat),
            messages: [specialMessage()]))
        XCTAssertEqual(ownIDs.compactMap { $0 }.count, 1)
        _ = try await sourceFactsValue(specialSeed(box, cache: nil))
        guard let foreign = snapshot(try await read(box)) else { return }
        XCTAssertEqual(foreign.messageFee, .unavailable)
        let foreignIDs = try await sourceFactsValue(specialEnqueue(box, context: specialContext(),
            messages: [specialMessage()]))
        XCTAssertTrue(foreignIDs.isEmpty)
    }

    // RPC accepts integer stars; truncation or negative amounts cannot be consented.
    func testMalformedFractionalAndNegativeFeeNeverBecomesFreeOrPayable() async throws {
        let box = try await box()
        for fee in [StarsAmount(value: -1, nanos: 0), .init(value: 0, nanos: 1),
            .init(value: 7, nanos: -1), .init(value: 7, nanos: 1_000_000_000)] {
            _ = try await sourceFactsValue(specialSeed(box, cache: CachedUserData().withUpdatedSendPaidMessageStars(fee)))
            guard let current = snapshot(try await read(box)) else { continue }
            XCTAssertEqual(current.messageFee, .unavailable)
        }
    }

    // Cached channel fee overrides peer fallback, including an explicit zero.
    func testChannelFeeOverrideFallbackAndAdminExemptionUseFreshPeer() async throws {
        let box = try await box(), chat = specialChannel().id.toInt64()
        let cases: [(TelegramChannel, CachedChannelData, TelegramMessageFee)] = [
            (specialChannel(fee: .init(value: 5, nanos: 0)), CachedChannelData(), .stars(5)),
            (specialChannel(fee: .init(value: 5, nanos: 0)), CachedChannelData().withUpdatedSendPaidMessageStars(.zero), .free),
            (specialChannel(fee: .init(value: 5, nanos: 0)), CachedChannelData().withUpdatedSendPaidMessageStars(.init(value: 2, nanos: 0)), .stars(2)),
            (specialChannel(fee: .init(value: 5, nanos: 0), admin: true), CachedChannelData(), .free)]
        for (peer, cache, expected) in cases {
            _ = try await sourceFactsValue(specialSeed(box, peer: peer, cache: cache))
            guard let current = snapshot(try await read(box, chat: chat)) else { continue }
            XCTAssertEqual(current.messageFee, expected)
        }
        _ = try await sourceFactsValue(specialSeed(box, peer: specialChannel(flags: [.isForum, .isMonoforum]), cache: CachedChannelData()))
        let mono = try await read(box, chat: chat)
        XCTAssertEqual(mono, .failure(.unsupported))
    }

    // Secret chat stays distinct from its regular participant and ordinary fee.
    func testSecretLifecycleParticipantAndFingerprintReadOnlyMapping() async throws {
        let box = try await box(), chat = specialSecret().id.toInt64()
        let cases: [(SecretChatEmbeddedPeerState, SecretChatEmbeddedState, TelegramSecretConversation.State)] = [
            (.handshake, .handshake(.accepting), .handshake), (.active, .basicLayer, .active),
            (.terminated, .terminated, .terminated)]
        for (peerState, full, expected) in cases {
            _ = try await sourceFactsValue(specialSeed(box, peer: specialSecret(peerState), cache: nil,
                state: specialSecretState(full)))
            guard let current = snapshot(try await read(box, chat: chat)) else { continue }
            XCTAssertEqual(current.chatID, chat); XCTAssertNotEqual(current.chatID, current.secret?.regularPeerID)
            XCTAssertEqual(current.secret?.regularPeerID, specialUser().id.toInt64())
            XCTAssertEqual(current.secret?.participantTitle, "Synthetic Participant")
            XCTAssertEqual(current.secret?.state, expected); XCTAssertEqual(current.messageFee, .free)
            if expected == .active {
                XCTAssertEqual(current.secret?.verification?.sha1, Data(0..<20))
                XCTAssertEqual(current.secret?.verification?.sha256, Data(32..<64))
            }
        }
    }

    // Reference comparison is four exact 8-byte hex rows, not the private key.
    func testVerificationHexRowsAndMalformedLengths() {
        guard let verification = TelegramSecretChatVerification(sha1: Data(0..<20), sha256: Data(32..<64)) else {
            return XCTFail("Valid public fingerprint was refused")
        }
        XCTAssertEqual(verification.hexLines, ["00 01 02 03 04 05 06 07", "08 09 0A 0B 0C 0D 0E 0F", "20 21 22 23 24 25 26 27", "28 29 2A 2B 2C 2D 2E 2F"])
        XCTAssertNil(TelegramSecretChatVerification(sha1: Data(count: 19), sha256: Data(count: 32)))
        XCTAssertNil(TelegramSecretChatVerification(sha1: Data(count: 20), sha256: Data(count: 33)))
    }

    // A key-only write must update the visible verification, even if native == omits it.
    func testNativeSignalTracksKeyOnlyChangesAndDisposal() async throws {
        let box = try await box(), chat = specialSecret().id.toInt64()
        _ = try await sourceFactsValue(specialSeed(box, peer: specialSecret(), cache: nil, state: specialSecretState()))
        let first = expectation(description: "First key"), changed = expectation(description: "Changed key")
        var observed: [Data] = []
        let lease = telegramConversationCapabilitiesSignal(postbox: box, accountID: 1, chatID: chat).start(next: { value in
            MainActor.assumeIsolated {
                guard case let .success(current) = value, let bytes = current.secret?.verification?.sha1 else { return }
                observed.append(bytes)
                if bytes == Data(0..<20) { first.fulfill() }
                if bytes == Data(1..<21) { changed.fulfill() }
            }
        })
        await fulfillment(of: [first], timeout: 2)
        _ = try await sourceFactsValue(specialState(box, variant: 1))
        await fulfillment(of: [changed], timeout: 2)
        lease.dispose()
        _ = try await sourceFactsValue(specialState(box, variant: 2))
        XCTAssertEqual(observed, [Data(0..<20), Data(1..<21)])
    }

    // Locked content price is media entitlement, not approval for an outgoing fee.
    func testPaidMediaLockedAndFullAreDistinctFromMessageFee() {
        let preview = TelegramExtendedMedia.preview(dimensions: nil, immediateThumbnailData: nil, videoDuration: nil)
        let image = TelegramMediaImage(imageId: .init(namespace: 0, id: 1), representations: [],
            immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        XCTAssertEqual(telegramPaidMediaState(.init(amount: 9, extendedMedia: [preview]))?.access, .locked)
        XCTAssertEqual(telegramPaidMediaState(.init(amount: 9, extendedMedia: [.full(media: image)]))?.access, .full)
        let mixed = telegramPaidMediaState(.init(amount: 9, extendedMedia: [preview, .full(media: image)]))
        XCTAssertEqual(mixed?.access, .mixed); XCTAssertEqual(mixed?.itemCount, 2); XCTAssertEqual(mixed?.amount, 9)
        XCTAssertNil(telegramPaidMediaState(.init(amount: -1, extendedMedia: [preview])))
        XCTAssertNil(telegramPaidMediaState(.init(amount: 9, extendedMedia: [])))
    }

    // A failed special guard must prevent real native local queue insertion.
    func testFreeNativeQueueRequiresNoPaidAttributesAndExactCount() async throws {
        let box = try await box(), context = specialContext()
        _ = try await sourceFactsValue(specialSeed(box))
        for messages in [[specialMessage(stars: 1)], [specialMessage(), specialMessage()]] {
            let ids = try await sourceFactsValue(specialEnqueue(box, context: context, messages: messages))
            XCTAssertEqual(ids, [])
        }
        let messages = [specialMessage()]
        let ids = try await sourceFactsValue(specialEnqueue(box, context: context, messages: messages))
        XCTAssertEqual(ids.compactMap { $0 }.count, 1)
    }

    // Active secret admission is plaintext-only and requires a usable native key.
    func testSecretGuardRejectsLifecycleMissingKeyMediaReplyAndFee() async throws {
        let box = try await box(), context = specialContext(chat: specialSecret().id.toInt64())
        for state in [specialSecretState(.terminated), specialSecretState(.handshake(.accepting)),
            specialSecretState(keyBytes: 0), specialSecretState(keyBytes: 255), specialSecretState(fingerprint: false)] {
            _ = try await sourceFactsValue(specialSeed(box, peer: specialSecret(), cache: nil, state: state))
            let allowed = try await sourceFactsValue(specialAllowed(box, context: context, messages: [specialMessage()]))
            XCTAssertFalse(allowed)
        }
        _ = try await sourceFactsValue(specialSeed(box, peer: specialSecret(), cache: nil, state: specialSecretState()))
        let allowed = try await sourceFactsValue(specialAllowed(box, context: context, messages: [specialMessage()]))
        XCTAssertTrue(allowed)
        for message in [specialMessage(stars: 1), specialMessage(reply: true), specialMessage(media: true),
            .forward(source: .init(peerId: specialUser().id, namespace: Namespaces.Message.Cloud, id: 1),
                threadId: nil, grouping: .none, attributes: [], correlationId: nil)] {
            let denied = try await sourceFactsValue(specialAllowed(box, context: context, messages: [message]))
            XCTAssertFalse(denied)
        }
    }

    // Base special guard cannot accidentally authorize a not-yet-validated topic.
    func testUnknownPeerAndUnvalidatedThreadFailClosed() async throws {
        let box = try await box()
        _ = try await sourceFactsValue(specialSeed(box))
        for context in [specialContext(chat: 999), specialContext(count: 0), specialContext(thread: 1)] {
            let allowed = try await sourceFactsValue(specialAllowed(box, context: context, messages: [specialMessage(thread: context.threadID)]))
            XCTAssertFalse(allowed)
        }
    }
    // Native encrypted RPCs take Int32 chat IDs; malformed positive peer IDs
    // must not pass admission and reach the native trapping conversion.
    func testOversizedSecretPeerIDCannotAuthorizeNativeEncryptedSend() async throws {
        let box = try await box(), peer = specialSecret(number: Int64(1) << 32)
        _ = try await sourceFactsValue(specialSeed(box, peer: peer, cache: nil, state: specialSecretState()))
        let allowed = try await sourceFactsValue(specialAllowed(box,
            context: specialContext(chat: peer.id.toInt64()), messages: [specialMessage()]))
        XCTAssertFalse(allowed)
    }

}

@MainActor final class TelegramPaidSendConsentTests: TelegramSourceFactsIntegrationTestCase {
    private func box() async throws -> Postbox {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        let box = try await sourceFactsOpen(path)
        _ = try await sourceFactsValue(specialSeed(box, cache: CachedUserData().withUpdatedSendPaidMessageStars(.init(value: 7, nanos: 0))))
        return box
    }

    private func create(_ box: Postbox, context: TelegramSendContext, id: UUID) async throws -> TelegramPaidSendConsent? {
        let result = try await sourceFactsValue(specialCreate(box, context: context, id: id))
        guard case let .success(consent) = result else { XCTFail("Explicit matching fee confirmation failed"); return nil }
        return consent
    }

    // Approval is persisted by an explicit operation, never fabricated by admission.
    func testExplicitConfirmationPersistsExactPendingConsentAndIsIdempotent() async throws {
        let box = try await box(), context = specialContext(count: 2), id = UUID()
        let initiallyDenied = try await sourceFactsValue(specialAllowed(box, context: context,
            messages: [specialMessage(stars: 7), specialMessage(stars: 7)], consentID: id))
        XCTAssertFalse(initiallyDenied)
        guard let consent = try await create(box, context: context, id: id),
            let repeatConsent = try await create(box, context: context, id: id) else { return }
        XCTAssertEqual(consent, repeatConsent); XCTAssertEqual(consent.context, context)
        XCTAssertEqual(consent.perMessageStars, 7); XCTAssertEqual(consent.totalStars, 14)
        let result = try await sourceFactsValue(specialRead(box, context: context, id: id))
        guard case let .success(record?) = result else { return XCTFail("Pending consent is not recoverable") }
        XCTAssertEqual(record.consent, consent); XCTAssertEqual(record.state, .pending)
    }

    // Changed account/chat/thread/revision/count/price cannot reuse a confirmation.
    func testConsentBindingAndCurrentPriceAreCheckedAtAdmission() async throws {
        let box = try await box(), context = specialContext(), id = UUID()
        guard try await create(box, context: context, id: id) != nil else { return }
        let message = specialMessage(stars: 7)
        let valid = try await sourceFactsValue(specialAllowed(box, context: context, messages: [message], consentID: id))
        XCTAssertTrue(valid)
        for foreign in [specialContext(account: 2, revision: context.submissionRevision),
            specialContext(chat: 43, revision: context.submissionRevision), specialContext(),
            specialContext(revision: context.submissionRevision, count: 2),
            specialContext(revision: context.submissionRevision, thread: 1)] {
            let allowed = try await sourceFactsValue(specialAllowed(box, context: foreign, messages: [message], consentID: id))
            XCTAssertFalse(allowed)
        }
        _ = try await sourceFactsValue(specialSeed(box, cache: CachedUserData().withUpdatedSendPaidMessageStars(.init(value: 8, nanos: 0))))
        let changed = try await sourceFactsValue(specialAllowed(box, context: context, messages: [message], consentID: id))
        XCTAssertFalse(changed)
    }

    // The actual payload must carry exactly the approved fee once per message.
    func testMissingDuplicatePostponedAndWrongFeeAttributesCannotUseConsent() async throws {
        let box = try await box(), context = specialContext(), id = UUID()
        guard try await create(box, context: context, id: id) != nil else { return }
        for message in [specialMessage(), specialMessage(stars: 8), specialMessage(stars: 7, duplicate: true),
            specialMessage(stars: 7, postpone: true)] {
            let allowed = try await sourceFactsValue(specialAllowed(box, context: context, messages: [message], consentID: id))
            XCTAssertFalse(allowed)
        }
    }

    // Native queue insertion and receipt consumption share the same transaction.
    func testAcceptedNativeIDsRecoverAfterLostACKAndNeverAuthorizeDuplicateInsertion() async throws {
        let box = try await box(), context = specialContext(count: 2), id = UUID()
        guard try await create(box, context: context, id: id) != nil else { return }
        let messages = [specialMessage(stars: 7), specialMessage(stars: 7)]
        let enqueue = specialEnqueue(box, context: context, messages: messages, consentID: id)
        let ids = try await sourceFactsValue(enqueue)
        XCTAssertEqual(ids.compactMap { $0 }.count, 2)
        let record = try await sourceFactsValue(specialRead(box, context: context, id: id))
        guard case let .success(value?) = record, case let .accepted(recovered) = value.state else {
            return XCTFail("Lost UI acknowledgement did not retain accepted native IDs")
        }
        XCTAssertEqual(recovered.map(\.peerID), [context.chatID, context.chatID])
        XCTAssertEqual(recovered.map(\.messageID), ids.compactMap { $0?.id })
        XCTAssertEqual(Set(recovered).count, 2)
        let publicRecovery = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: context, consentID: id))
        XCTAssertEqual(publicRecovery, .success(.accepted(recovered)))
        let duplicate = try await sourceFactsValue(enqueue)
        XCTAssertEqual(duplicate, [])
        let unchanged = try await sourceFactsValue(specialRead(box, context: context, id: id))
        guard case let .success(after?) = unchanged else { return XCTFail("Receipt disappeared after retry") }
        XCTAssertEqual(after, value)
    }

    // Native commit cannot throw/roll back insertion. Started must survive a
    // partial result and forbid another admission after restart/lost callback.
    func testStartedConsentSurvivesPartialNativeResultAndNeverAuthorizesRetry() async throws {
        let box = try await box(), context = specialContext(count: 2), id = UUID()
        guard try await create(box, context: context, id: id) != nil else { return }
        let begin = try await sourceFactsValue(specialBegin(box, context: context, id: id))
        if case .failure = begin { return XCTFail("Valid pending consent did not start") }
        let partial = try await sourceFactsValue(specialConsume(box, context: context, id: id,
            ids: [MessageId(peerId: specialUser().id, namespace: Namespaces.Message.Local, id: 1), nil]))
        if case .success = partial { XCTFail("Partial native result became accepted") }
        let recovery = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: context, consentID: id))
        XCTAssertEqual(recovery, .success(.submissionStarted))
        let retry = try await sourceFactsValue(specialAllowed(box, context: context,
            messages: [specialMessage(stars: 7), specialMessage(stars: 7)], consentID: id))
        XCTAssertFalse(retry)
        let repeatBegin = try await sourceFactsValue(specialBegin(box, context: context, id: id))
        if case .success = repeatBegin { XCTFail("Uncertain started consent was restarted") }
    }

    // Removing complete/distinct/native/author/fee validation must fail this
    // receipt test after begin has succeeded, rather than merely denying pending.
    func testInvalidAcceptedIDsPreserveStartedUntilCompleteNativeReceipt() async throws {
        let box = try await box(), context = specialContext(count: 2), id = UUID()
        guard try await create(box, context: context, id: id) != nil else { return }
        let begin = try await sourceFactsValue(specialBegin(box, context: context, id: id))
        if case .failure = begin { return XCTFail("Valid pending receipt did not start") }
        _ = try await sourceFactsValue(specialSeed(box, peer: specialUser(2)))
        _ = try await sourceFactsValue(specialSeed(box, peer: specialUser(43)))
        let valid = try await sourceFactsValue(specialReceiptFixture(box,
            messages: [specialMessage(stars: 7), specialMessage(stars: 7)])).compactMap { $0 }
        let wrongAuthor = try await sourceFactsValue(specialReceiptFixture(box, account: 2,
            messages: [specialMessage(stars: 7)])).compactMap { $0 }
        let wrongFee = try await sourceFactsValue(specialReceiptFixture(box,
            messages: [specialMessage(stars: 8)])).compactMap { $0 }
        let foreign = try await sourceFactsValue(specialReceiptFixture(box, chat: specialUser(43).id,
            messages: [specialMessage(stars: 7)])).compactMap { $0 }
        guard valid.count == 2, wrongAuthor.count == 1, wrongFee.count == 1, foreign.count == 1 else {
            return XCTFail("Native receipt fixture did not insert expected local messages")
        }
        let invalidIDs: [[MessageId?]] = [[valid[0]], [valid[0], nil], [valid[0], valid[0]],
            [foreign[0], valid[0]], [wrongAuthor[0], valid[0]], [wrongFee[0], valid[0]],
            [.init(peerId: specialUser().id, namespace: Namespaces.Message.Cloud, id: 1), valid[0]],
            [valid[0], .init(peerId: specialUser().id, namespace: Namespaces.Message.Local, id: Int32.max)]]
        for ids in invalidIDs {
            let rejected = try await sourceFactsValue(specialConsume(box, context: context, id: id, ids: ids))
            if case .success = rejected { XCTFail("Invalid native queue IDs consumed consent") }
            let recovery = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: context, consentID: id))
            XCTAssertEqual(recovery, .success(.submissionStarted))
        }
        let accepted = try await sourceFactsValue(specialConsume(box, context: context, id: id, ids: valid.map(Optional.some)))
        if case .failure = accepted { return XCTFail("Complete same-account native receipt was rejected") }
        let recovery = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: context, consentID: id))
        XCTAssertEqual(recovery, .success(.accepted([
            .init(peerID: context.chatID, namespace: Namespaces.Message.Local, messageID: valid[0].id),
            .init(peerID: context.chatID, namespace: Namespaces.Message.Local, messageID: valid[1].id)
        ])))
    }

    // Checked multiplication and fresh-price matching happen before writing approval.
    func testOverflowZeroCountAndStaleConfirmationCreateNoJournal() async throws {
        let box = try await box()
        for (context, price) in [(specialContext(count: 0), Int64(7)), (specialContext(), Int64(8)),
            (specialContext(count: 101), Int64(7)), (specialContext(count: Int.max), Int64(7))] {
            let id = UUID()
            let result = try await sourceFactsValue(specialCreate(box, context: context, price: price, id: id))
            if case .success = result { XCTFail("Invalid confirmation created approval") }
            let bytes = try await sourceFactsValue(specialRaw(box, context: context, id: id))
            XCTAssertNil(bytes)
        }
    }

    // Unknown bytes must not be overwritten or interpreted as an approval.
    func testCorruptJournalFailsClosedAndPreservesOriginalBytes() async throws {
        let box = try await box(), context = specialContext(), id = UUID(), bytes = Data([0x7b])
        _ = try await sourceFactsValue(specialCorrupt(box, context: context, id: id, bytes: bytes))
        let result = try await sourceFactsValue(specialRead(box, context: context, id: id))
        if case .success = result { XCTFail("Corrupt journal was accepted or hidden") }
        let recreate = try await sourceFactsValue(specialCreate(box, context: context, id: id))
        if case .success = recreate { XCTFail("Corrupt journal was overwritten") }
        let unchanged = try await sourceFactsValue(specialRaw(box, context: context, id: id))
        XCTAssertEqual(unchanged, bytes)
    }
    // The production receipt boundary owns guard→begin→native insert→consume.
    func testSharedReceiptQueuesAcceptedIDsAndRejectsDuplicateAdmission() async throws {
        let box = try await box(), context = specialContext(count: 2), id = UUID()
        guard let consent = try await create(box, context: context, id: id) else { return }
        let queue = specialAuthorizedEnqueue(box, context: context,
            messages: [specialMessage(stars: 7), specialMessage(stars: 7)], consent: consent)
        let ids = try await sourceFactsValue(queue)
        XCTAssertEqual(ids.compactMap { $0 }.count, 2)
        let recovery = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: context, consentID: id))
        guard case let .success(recovered?) = recovery, case let .accepted(accepted) = recovered else {
            return XCTFail("Production receipt did not persist acceptance")
        }
        XCTAssertEqual(accepted.map(\.messageID), ids.compactMap { $0?.id })
        let retry = try await sourceFactsValue(queue)
        XCTAssertEqual(retry, [])
    }

    // A native missing-forward result cannot leave a reusable paid approval.
    func testSharedReceiptRetainsStartedAfterActualPartialNativeQueueResult() async throws {
        let box = try await box(), context = specialContext(), id = UUID()
        guard let consent = try await create(box, context: context, id: id) else { return }
        let absent = MessageId(peerId: specialUser(999).id, namespace: Namespaces.Message.Cloud, id: 99)
        let forward = EnqueueMessage.forward(source: absent, threadId: nil, grouping: .none,
            attributes: [PaidStarsMessageAttribute(stars: .init(value: 7, nanos: 0), postponeSending: false)], correlationId: nil)
        let queue = specialAuthorizedEnqueue(box, context: context, messages: [forward], consent: consent)
        let ids = try await sourceFactsValue(queue)
        XCTAssertTrue(ids.compactMap { $0 }.isEmpty)
        let recovery = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: context, consentID: id))
        XCTAssertEqual(recovery, .success(.submissionStarted))
        let retry = try await sourceFactsValue(queue)
        XCTAssertEqual(retry, [])
    }

    // The actual shared admission factory must run specific CAS/permissions
    // before begin; a denied preparation must keep its paid approval pending.
    func testSharedAdmissionFactoryChecksSpecificBoundaryBeforeConsumingConsent() async throws {
        let box = try await box(), context = specialContext(), id = UUID()
        guard let consent = try await create(box, context: context, id: id) else { return }
        let messages = [specialMessage(stars: 7)]
        let denied = try await sourceFactsValue(specialAuthorizedEnqueue(box, context: context,
            messages: messages, consent: consent, specificAdmission: false))
        XCTAssertEqual(denied, [])
        let pending = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: context, consentID: id))
        XCTAssertEqual(pending, .success(.pending))
        let accepted = try await sourceFactsValue(specialAuthorizedEnqueue(box, context: context,
            messages: messages, consent: consent))
        XCTAssertEqual(accepted.compactMap { $0 }.count, 1)
        let recovery = try await sourceFactsValue(telegramPaidSendConsentRecovery(postbox: box, context: context, consentID: id))
        guard case let .success(recovered?) = recovery, case .accepted = recovered else {
            return XCTFail("Specific rejection consumed reusable pending approval")
        }
    }

}

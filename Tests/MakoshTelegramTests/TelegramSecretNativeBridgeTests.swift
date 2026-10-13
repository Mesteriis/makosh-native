import XCTest
import Security
import TelegramCore
@testable import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramSecretNativeBridgeTests: XCTestCase {
    func testCreationBasisRefusesOwnAccountAndBindsPremiumAndUserRevision() throws {
        let peer = secretBridgeUser(42, hash: 88)
        let allowed = try XCTUnwrap(telegramSecretCreationBasis(peer: peer, accountID: 101, premiumRequired: false))
        XCTAssertTrue(allowed.canCreate); XCTAssertTrue(allowed.isValid)
        XCTAssertNil(telegramSecretCreationBasis(peer: peer, accountID: 42, premiumRequired: false))
        let premium = try XCTUnwrap(telegramSecretCreationBasis(peer: peer, accountID: 101, premiumRequired: true))
        XCTAssertFalse(premium.canCreate); XCTAssertNotEqual(allowed.revision, premium.revision)
        let changed = try XCTUnwrap(telegramSecretCreationBasis(peer: secretBridgeUser(42, hash: 89), accountID: 101, premiumRequired: false))
        XCTAssertNotEqual(allowed.revision, changed.revision)
        XCTAssertFalse(try XCTUnwrap(telegramSecretCreationBasis(peer: secretBridgeUser(42), accountID: 101, premiumRequired: false)).canCreate)
    }
    func testNativeEntropyFailureNeverProducesASecretExponentBuffer() {
        var requested = 0
        let result = makoshSecretChatRandomBuffer { _, count in requested = count; return errSecNotAvailable }
        XCTAssertEqual(requested, 256); XCTAssertNil(result)
    }
    func testNativeEntropySuccessPreservesAll256Bytes() throws {
        let result = try XCTUnwrap(makoshSecretChatRandomBuffer { pointer, count in
            pointer.initializeMemory(as: UInt8.self, repeating: 0x5a, count: count); return errSecSuccess
        })
        XCTAssertEqual(result.length, 256); XCTAssertEqual(result.makeData(), Data(repeating: 0x5a, count: 256))
    }
    func testLayerAdmissionUsesTheActualNativeEntityEncoder() {
        let bold = [MessageTextEntity(range: 0..<4, type: .Bold)]
        XCTAssertFalse(makoshSecretEntitiesAreLossless(bold, layer: 46))
        XCTAssertTrue(makoshSecretEntitiesAreLossless(bold, layer: 73))
        let underline = [MessageTextEntity(range: 0..<4, type: .Underline)]
        XCTAssertFalse(makoshSecretEntitiesAreLossless(underline, layer: 73))
        XCTAssertTrue(makoshSecretEntitiesAreLossless(underline, layer: 101))
        let spoiler = [MessageTextEntity(range: 0..<4, type: .Spoiler)]
        XCTAssertFalse(makoshSecretEntitiesAreLossless(spoiler, layer: 101))
        XCTAssertTrue(makoshSecretEntitiesAreLossless(spoiler, layer: 144))
        XCTAssertFalse(makoshSecretEntitiesAreLossless(bold, layer: 999))
    }
    func testUnsupportedOrLossyEntityFieldsCannotBeSilentlyDropped() {
        for kind in [MessageTextEntityType.Pre(language: "swift"), .BlockQuote(isCollapsed: true), .PhoneNumber,
                     .TextMention(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42)))] {
            XCTAssertFalse(makoshSecretEntitiesAreLossless([.init(range: 0..<4, type: kind)], layer: 144))
        }
        XCTAssertTrue(makoshSecretEntitiesAreLossless([.init(range: 0..<4, type: .Pre(language: nil))], layer: 144))
        XCTAssertTrue(makoshSecretEntitiesAreLossless([.init(range: 0..<4, type: .BlockQuote(isCollapsed: false))], layer: 101))
        XCTAssertFalse(makoshSecretEntitiesAreLossless([.init(range: 0..<Int.max, type: .Bold)], layer: 144))
    }
}

private nonisolated func secretBridgeUser(_ number: Int64, hash: Int64? = nil) -> TelegramUser {
    .init(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(number)), accessHash: hash.map { .personal($0) },
        firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil,
        flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
        profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private nonisolated func secretTTLBridgeFixture(_ box: Postbox, rawID: Int64 = 44, active: Bool = true, admit: Bool = true, accountPresent: Bool = true, keyBytes: Int = 256)
    -> Signal<(queued: Bool, namespace: Int32?, peerMatches: Bool, peerTTL: Int32?, stateTTL: Int32?, actionTTL: Int32?, duplicateQueued: Bool), NoError> {
    box.transaction { transaction in
        let own = secretBridgeUser(101), regular = secretBridgeUser(42)
        let id = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(rawID))
        let peer = TelegramSecretChat(id: id, creationDate: 1000, regularPeerId: regular.id, accessHash: 88, role: .creator,
            embeddedState: active ? .active : .handshake, messageAutoremoveTimeout: nil)
        let sequence = SecretChatSequenceBasedLayerState(layerNegotiationState: .init(activeLayer: .layer144, locallyRequestedLayer: 144, remotelyRequestedLayer: 144),
            rekeyState: nil, baseIncomingOperationIndex: 0, baseOutgoingOperationIndex: 0, topProcessedCanonicalIncomingOperationIndex: nil)
        let state = SecretChatState(role: .creator, embeddedState: active ? .sequenceBasedLayer(sequence) : .handshake(.accepting),
            keychain: .init(keys: [.init(fingerprint: 1, key: MemoryBuffer(data: Data(repeating: 0x5a, count: keyBytes)), validity: .indefinite, useCount: 0)]),
            keyFingerprint: .init(sha1: .init(digest: Data(0..<20)), sha256: .init(digest: Data(32..<64))), messageAutoremoveTimeout: nil)
        let peers: [Peer] = accountPresent ? [own, regular, peer] : [regular, peer]
        transaction.updatePeersInternal(peers, update: { _, value in value })
        transaction.setPeerChatState(id, state: state)
        let messageID = makoshEnqueueSecretTTL(transaction: transaction, accountPeerId: own.id, peerId: id, timeout: 60,
            timestamp: 1000, isSupportUser: false, admission: { _ in admit })
        var actionTTL: Int32?
        if let messageID, let message = transaction.getMessage(messageID) {
            for media in message.media {
                if let action = media as? TelegramMediaAction, case let .messageAutoremoveTimeoutUpdated(period, _) = action.action { actionTTL = period }
            }
        }
        let duplicate = messageID == nil ? nil : makoshEnqueueSecretTTL(transaction: transaction, accountPeerId: own.id, peerId: id, timeout: 60,
            timestamp: 1001, isSupportUser: false, admission: { _ in true })
        return (messageID != nil, messageID?.namespace, messageID?.peerId == id,
            (transaction.getPeer(id) as? TelegramSecretChat)?.messageAutoremoveTimeout,
            (transaction.getPeerChatState(id) as? SecretChatState)?.messageAutoremoveTimeout, actionTTL, duplicate != nil)
    }
}
@MainActor final class TelegramSecretTTLBridgeTests: XCTestCase {
    func testTTLAndExactNativeServiceMessageAreCommittedTogether() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(secretTTLBridgeFixture(box), test: self)
        XCTAssertTrue(value.queued); XCTAssertEqual(value.namespace, Namespaces.Message.Local); XCTAssertTrue(value.peerMatches)
        XCTAssertEqual(value.peerTTL, 60); XCTAssertEqual(value.stateTTL, 60); XCTAssertEqual(value.actionTTL, 60)
        XCTAssertFalse(value.duplicateQueued)
    }
    func testNativeNegativeSecretIDCanQueueItsOwnTTLService() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(secretTTLBridgeFixture(box, rawID: -44), test: self)
        XCTAssertTrue(value.queued); XCTAssertTrue(value.peerMatches); XCTAssertEqual(value.actionTTL, 60)
    }
    func testCancelledAdmissionDoesNotChangeNativeTimer() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(secretTTLBridgeFixture(box, admit: false), test: self)
        XCTAssertFalse(value.queued); XCTAssertNil(value.peerTTL); XCTAssertNil(value.stateTTL)
    }
    func testHandshakeCannotChangeTimerOrClaimAnOutboxReceipt() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(secretTTLBridgeFixture(box, active: false), test: self)
        XCTAssertFalse(value.queued); XCTAssertNil(value.peerTTL); XCTAssertNil(value.stateTTL)
    }
    func testMissingOwnAccountCannotClaimQueueAdmissionOrUpdateTimer() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(secretTTLBridgeFixture(box, accountPresent: false), test: self)
        XCTAssertFalse(value.queued); XCTAssertNil(value.peerTTL); XCTAssertNil(value.stateTTL)
    }
    func testMalformedNativeKeyCannotQueueTTLOrChangeLocalState() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(secretTTLBridgeFixture(box, keyBytes: 255), test: self)
        XCTAssertFalse(value.queued); XCTAssertNil(value.peerTTL); XCTAssertNil(value.stateTTL)
    }
}

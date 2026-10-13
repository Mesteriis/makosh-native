import XCTest
@testable import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramCallAccountBoundaryTests: XCTestCase {
    func testFullCallPeerIsCachedBeforeNativeRequestReadsInputHash() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(callCachePacket(box, result: telegramCallFullUserFixture(hash: 88), peerID: 42), test: self)
        XCTAssertEqual(value.0?.peerID, 42); XCTAssertEqual(value.1, "Synthetic Alice")
        guard case let .inputUser(id, hash) = value.2 else { return XCTFail("Missing full native input user") }
        XCTAssertEqual(id, 42); XCTAssertEqual(hash, 88)
    }
    func testForeignFullUserCannotPartiallySeedCallPeerCache() async throws {
        let box = try await telegramDataPostbox(test: self)
        let value = try await telegramDataValue(callCachePacket(box, result: telegramCallFullUserFixture(), peerID: 43), test: self)
        XCTAssertNil(value.0); XCTAssertNil(value.1); XCTAssertNil(value.2)
    }
    func testNativeRingingIdentityIsAccountBoundAndUnknownCallerIsExplicit() throws {
        let id = UUID(), peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42))
        let row = CallSessionRingingState(id: id, peerId: peer, isVideo: true, isVideoPossible: true, conferenceSource: nil, otherParticipants: [])
        let values = try XCTUnwrap(telegramCallIncoming(states: [row], accountID: 101, peers: [:]))
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values[0].accountID, 101); XCTAssertEqual(values[0].peerID, 42)
        XCTAssertEqual(values[0].title, "Пользователь 42"); XCTAssertEqual(values[0].id, id)
        XCTAssertNil(telegramCallIncoming(states: [row, row], accountID: 101, peers: [:]))
        XCTAssertNil(telegramCallIncoming(states: [row], accountID: 42, peers: [:]))
    }
    func testConferenceRingingCannotBeOfferedAsOneToOneCall() throws {
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42))
        let row = CallSessionRingingState(id: UUID(), peerId: peer, isVideo: true, isVideoPossible: true,
            conferenceSource: .init(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1), otherParticipants: [])
        XCTAssertEqual(try XCTUnwrap(telegramCallIncoming(states: [row], accountID: 101, peers: [:])), [])
    }
}
private nonisolated func callCachePacket(_ box: Postbox, result: Api.users.UserFull, peerID: Int64) -> Signal<(TelegramCallPeer?, String?, Api.InputUser?), NoError> {
    box.transaction { transaction in
        let value = telegramCommitCallPeer(transaction: transaction, result: result, accountID: 101, peerID: peerID)
        let id = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42))
        let title = (transaction.getPeer(id) as? TelegramUser)?.firstName
        let input = telegramCallUserInput(transaction: transaction, accountID: 101, peerID: peerID)
        return (value, title, input)
    }
}

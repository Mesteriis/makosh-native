import XCTest
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramRemotePeerNativeTests: XCTestCase {
    func testSearchWireUsesPinnedContactsConstructorAndBoundedLimit() throws {
        let rpc = try XCTUnwrap(telegramRemotePeerSearchRPC("@alice"))
        XCTAssertEqual(rpc.0.name, "contacts.search")
        XCTAssertEqual(rpc.0.parameters.map { String(describing: $0.1) }, ["alice", "20"])
        XCTAssertNil(telegramRemotePeerSearchRPC("#alice"))
    }
    func testNativePeerMappingRejectsDeletedMissingHashAndSecretIdentity() {
        let id = PeerId(namespace: Namespaces.Peer.CloudUser,id: ._internalFromInt64Value(7))
        func user(_ hash: TelegramPeerAccessHash?, deleted: Bool = false) -> TelegramUser {
            TelegramUser(id:id, accessHash:hash, firstName:deleted ? nil : "Alice", lastName:nil, username:deleted ? nil : "alice", phone:nil, photo:[], botInfo:nil, restrictionInfo:nil, flags:[], emojiStatus:nil, usernames:[], storiesHidden:nil, nameColor:nil, backgroundEmojiId:nil, profileColor:nil, profileBackgroundEmojiId:nil, subscriberCount:nil, verificationIconFileId:nil)
        }
        XCTAssertNotNil(telegramDiscoveredPeer(user(.personal(77)), accountID:100))
        XCTAssertNil(telegramDiscoveredPeer(user(nil), accountID:100))
        XCTAssertNil(telegramDiscoveredPeer(user(.personal(77), deleted: true), accountID:100))
        XCTAssertNotNil(telegramDiscoveredPeer(user(nil), accountID:7), "Own identity uses inputUserSelf")
    }
}

private nonisolated func remotePacket(_ box: Postbox, result: Api.contacts.Found) -> Signal<([Int64], [Int64], Bool)?, NoError> {
    box.transaction { transaction in
        let account = PeerId(namespace: Namespaces.Peer.CloudUser,id: ._internalFromInt64Value(100))
        guard let (my, global) = makoshRemotePeerSearchResult(transaction:transaction,accountPeerId:account,result:result) else { return nil }
        let id = PeerId(namespace: Namespaces.Peer.CloudUser,id: ._internalFromInt64Value(7))
        return (my.map { $0.peer.id.toInt64() },global.map { $0.peer.id.toInt64() },transaction.getPeer(id) != nil)
    }
}
private nonisolated func storedRemotePeer(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { $0.getPeer(PeerId(namespace:Namespaces.Peer.CloudUser,id:._internalFromInt64Value(7))) != nil }
}
@MainActor final class TelegramRemotePeerPostboxTests: XCTestCase {
    private func user(hash: Int64? = 77, min: Bool = false) -> Api.User {
        .user(flags: 2 | (hash == nil ? 0 : 1) | (min ? 1 << 20 : 0),flags2:0,id:7,accessHash:hash,firstName:"Synthetic Alice",lastName:nil,username:nil,phone:nil,photo:nil,status:nil,botInfoVersion:nil,restrictionReason:nil,botInlinePlaceholder:nil,langCode:nil,emojiStatus:nil,usernames:nil,storiesMaxId:nil,color:nil,profileColor:nil,botActiveUsers:nil,botVerificationIcon:nil,sendPaidMessagesStars:nil)
    }
    func testNativeSearchCachesUsablePeerBeforePublishingResult() async throws {
        let box = try await telegramDataPostbox(test:self)
        let result = try await telegramDataValue(remotePacket(box,result:.found(myResults:[],results:[.peerUser(userId:7)],chats:[],users:[user()])),test:self)
        let value = try XCTUnwrap(result)
        XCTAssertEqual(value.0,[]); XCTAssertEqual(value.1,[7]); XCTAssertTrue(value.2)
    }
    func testUnresolvedOrMinSearchCannotPartiallySeedCache() async throws {
        let box = try await telegramDataPostbox(test:self)
        let unresolved = try await telegramDataValue(remotePacket(box,result:.found(myResults:[],results:[.peerUser(userId:8)],chats:[],users:[user()])),test:self)
        XCTAssertNil(unresolved)
        let min = try await telegramDataValue(remotePacket(box,result:.found(myResults:[],results:[.peerUser(userId:7)],chats:[],users:[user(min:true)])),test:self)
        XCTAssertNil(min)
        let stored = try await telegramDataValue(storedRemotePeer(box),test:self)
        XCTAssertFalse(stored)
    }
}

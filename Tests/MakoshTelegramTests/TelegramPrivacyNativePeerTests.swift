import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramPrivacyNativePeerTests: XCTestCase {
    private func user(_ id: Int64, hash: TelegramPeerAccessHash? = .personal(70)) -> TelegramUser {
        .init(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id)), accessHash: hash,
            firstName: "Synthetic", lastName: "Alice", username: nil, phone: nil, photo: [], botInfo: nil,
            restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil,
            backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
    }
    private func group(_ id: Int64, member: Bool = true) -> TelegramGroup {
        .init(id: PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(id)), title: "Synthetic Group", photo: [],
            participantCount: 3, role: .member, membership: member ? .Member : .Left, flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 1, version: 1)
    }
    func testCandidatesRejectSelfUnusableHashesAndDepartedGroups() {
        XCTAssertEqual(telegramPrivacyCandidate(user(7), selfID: 1)?.id, .user(7))
        XCTAssertEqual(telegramPrivacyCandidate(group(9), selfID: 1)?.id, .chat(9))
        XCTAssertNil(telegramPrivacyCandidate(user(1), selfID: 1))
        XCTAssertNil(telegramPrivacyCandidate(user(7, hash: nil), selfID: 1))
        XCTAssertNil(telegramPrivacyCandidate(user(7, hash: .genericPublic(70)), selfID: 1))
        XCTAssertNil(telegramPrivacyCandidate(group(9, member: false), selfID: 1))
    }
    func testOnlyNewUserHashesMayComeFromFreshLocalPeers() throws {
        let old = TelegramPrivacyTests.setting([.allowUsers([7]), .contacts])
        let sent = TelegramPrivacyTests.setting([.allowUsers([7,8]), .allowChats([9]), .contacts])
        XCTAssertEqual(telegramPrivacyAdditionHashes(current: old, sent: sent, freshHashes: [7: 71], peers: [user(8, hash: .personal(80)), group(9)], selfID: 1), [7: 71, 8: 80])
        XCTAssertNil(telegramPrivacyAdditionHashes(current: old, sent: sent, freshHashes: [7: 71], peers: [user(8)], selfID: 1))
        XCTAssertNil(telegramPrivacyAdditionHashes(current: old, sent: sent, freshHashes: [7: 71], peers: [user(8, hash: .genericPublic(80)), group(9)], selfID: 1))
        let hashes = try XCTUnwrap(telegramPrivacyAdditionHashes(current: old, sent: sent, freshHashes: [:], peers: [user(7), user(8), group(9)], selfID: 1))
        XCTAssertNil(telegramPrivacyInputRules(sent, userHashes: hashes, selfID: 1), "Existing user must still be resolved from the fresh server response")
    }
    func testDuplicateLocalIdentityCannotAdmitNewException() {
        let old = TelegramPrivacyTests.setting([.contacts]), sent = TelegramPrivacyTests.setting([.allowUsers([7]), .contacts])
        XCTAssertNil(telegramPrivacyAdditionHashes(current: old, sent: sent, freshHashes: [:], peers: [user(7), user(7)], selfID: 1))
    }
}

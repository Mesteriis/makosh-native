import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramRemotePeerSearchTests: XCTestCase {
    func testOrdinaryNamesAndUsernamesAdmitOnlySingleBoundedQuery() {
        XCTAssertEqual(TelegramRemotePeerQuery("  @alice_test  ")?.value, "alice_test")
        XCTAssertEqual(TelegramRemotePeerQuery("Мария Иванова")?.value, "Мария Иванова")
        for invalid in ["", "  ", "@", "#topic", "$star", "alice\nsecret", "a\0b", String(repeating: "a", count: 257)] {
            XCTAssertNil(TelegramRemotePeerQuery(invalid), invalid.debugDescription)
        }
    }
    func testResultGroupsDeduplicateByNativeIdentityAndKeepLocalBeforeGlobal() {
        let user = TelegramDiscoveredPeer(chat: .init(id: 7, title: "Alice", preview: "", unreadCount: 0), username: "alice")
        let groupID = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(7)).toInt64()
        let group = TelegramDiscoveredPeer(chat: .init(id: groupID, title: "Group", preview: "", unreadCount: 0), username: nil)
        XCTAssertEqual(telegramMergeDiscoveredPeers(my: [user], global: [user, group])?.map(\.chat.id), [7, groupID])
        XCTAssertEqual(telegramMergeDiscoveredPeers(my: [user], global: [group], excluding: [7])?.map(\.chat.id), [groupID])
    }
    func testMalformedResultRejectsPacketInsteadOfSilentlyTruncating() {
        let good = TelegramDiscoveredPeer(chat: .init(id: 7, title: "Alice", preview: "", unreadCount: 0), username: nil)
        let bad = TelegramDiscoveredPeer(chat: .init(id: 0, title: "Missing", preview: "", unreadCount: 0), username: nil)
        XCTAssertNil(telegramMergeDiscoveredPeers(my: [good], global: [bad]))
        XCTAssertNil(telegramMergeDiscoveredPeers(my: Array(repeating: good, count: 201), global: []))
    }
}

import XCTest
import MakoshCore
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramSecretFilePolicyTests: XCTestCase {
    private func identity(_ peer: PeerId) -> MessageArchiveIdentity {
        .init(service: "telegram", accountID: "101", conversationID: String(peer.toInt64()), messageID: "synthetic-file")
    }
    func testSecretConversationUsesThePersonalChatS3Default() {
        let secret = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(44))
        XCTAssertTrue(TelegramConversationFilePolicyController.defaultEnabled(identity: identity(secret)))
        let user = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42))
        XCTAssertTrue(TelegramConversationFilePolicyController.defaultEnabled(identity: identity(user)))
        for namespace in [Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel] {
            let group = PeerId(namespace: namespace, id: ._internalFromInt64Value(10))
            XCTAssertFalse(TelegramConversationFilePolicyController.defaultEnabled(identity: identity(group)))
        }
    }
    func testInvalidSecretNativeIDCannotGainAutomaticS3Admission() {
        let invalid = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(Int64(1) << 32))
        XCTAssertFalse(TelegramConversationFilePolicyController.defaultEnabled(identity: identity(invalid)))
    }
    func testNativeSignedSecretIDIsStillAPersonalConversation() {
        let secret = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(-44))
        XCTAssertTrue(TelegramConversationFilePolicyController.defaultEnabled(identity: identity(secret)))
    }
}

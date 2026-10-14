import XCTest
import Combine
import Postbox
import TelegramCore
@testable import MakoshTelegram
@testable import MakoshApp

final class TelegramCallTargetTests: XCTestCase {
    func testOrdinaryPrivateChatUsesCanonicalCloudUserAndRejectsSelfOrGroups() {
        XCTAssertEqual(telegramCallTarget(accountID: 101, chatID: 42, secret: nil), 42)
        XCTAssertNil(telegramCallTarget(accountID: 101, chatID: 101, secret: nil))
        let group = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(42)).toInt64()
        XCTAssertNil(telegramCallTarget(accountID: 101, chatID: group, secret: nil))
        XCTAssertNil(telegramCallTarget(accountID: nil, chatID: 42, secret: nil))
    }
    func testSecretChatCallsRegularPeerOnlyWithCurrentActiveCapabilities() {
        let id = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(42)).toInt64()
        let active = TelegramSecretConversation(regularPeerID: 43, participantTitle: "Synthetic Alice", state: .active, verification: nil)
        XCTAssertEqual(telegramCallTarget(accountID: 101, chatID: id, secret: active), 43)
        XCTAssertNil(telegramCallTarget(accountID: 101, chatID: id, secret: nil))
        let ended = TelegramSecretConversation(regularPeerID: 43, participantTitle: "Synthetic Alice", state: .terminated, verification: nil)
        XCTAssertNil(telegramCallTarget(accountID: 101, chatID: id, secret: ended))
    }
}

@MainActor final class TelegramCallModelTests: XCTestCase {
    func testSyntheticWorkspaceUsesExplicitInertPermissionsAndTracksSelectedPeer() {
        let model = TelegramModel.syntheticCallsPreview()
        XCTAssertEqual(model.calls.accountID, 101); XCTAssertEqual(model.callPeerID, 42)
        XCTAssertEqual(model.calls.peer?.peerID, 42)
        model.selectedChatID = 43
        XCTAssertEqual(model.calls.peer?.peerID, 43)
        model.selectedChatID = model.chats.last?.id
        XCTAssertNil(model.callPeerID); XCTAssertNil(model.calls.peer)
    }
    func testCallControlChangesRefreshWorkspaceWithoutForwardingFrames() throws {
        let model = TelegramModel.syntheticCallsPreview()
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        let peer = try XCTUnwrap(model.calls.peer)
        XCTAssertTrue(model.calls.startOutgoing(basis: peer, video: false, contextID: model.calls.peerContextID))
        XCTAssertGreaterThan(changes, 0)
    }
    func testClosingOwningWorkspaceCancelsPendingCallBeforePermissionWorkCanRun() throws {
        let model = TelegramModel.syntheticCallsPreview(), windows = TelegramCallWindows()
        windows.register(model.calls, synthetic: true)
        let peer = try XCTUnwrap(model.calls.peer)
        XCTAssertTrue(model.calls.startOutgoing(basis: peer, video: false, contextID: model.calls.peerContextID))
        // Unregister synchronously, before any queued window or permission task.
        windows.unregister(model.calls)
        XCTAssertEqual(model.calls.call?.isActive, false)
        XCTAssertFalse(model.calls.isBusy)
    }
    func testDisconnectRevokesSyntheticCallContextAndReleasesCoordinator() async throws {
        let model = TelegramModel.syntheticCallsPreview()
        let peer = try XCTUnwrap(model.calls.peer)
        XCTAssertTrue(model.calls.startOutgoing(basis: peer, video: false, contextID: model.calls.peerContextID))
        await Task.yield()
        model.disconnect()
        XCTAssertNil(model.calls.call); XCTAssertNil(model.calls.accountID)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.calls.isReleasingMedia); XCTAssertFalse(model.calls.isBusy)
    }
}

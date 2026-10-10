import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramPeerStatusControllerTests: XCTestCase {
    private func status(account: Int64 = 1, peer: Int64 = 42) -> TelegramPeerStatus {
        TelegramPeerStatus(accountID: account, peerID: peer, kind: .person, presence: .present(until: 2_000))
    }
    func testVisibilityChatAndAccountChangesDisposeAndRejectStaleStatus() {
        let controller = TelegramPeerStatusController()
        var callbacks: [(TelegramPeerStatus?) -> Void] = []
        var disposed = 0
        controller.bind(accountID: 1) { _ in Signal { subscriber in
            callbacks.append { subscriber.putNext($0) }; return ActionDisposable { disposed += 1 }
        } }
        controller.selectPeer(42); XCTAssertEqual(callbacks.count, 0)
        controller.setVisible(true); XCTAssertEqual(callbacks.count, 1)
        callbacks[0](status()); XCTAssertEqual(controller.status, status())
        callbacks[0](status(account: 2)); XCTAssertEqual(controller.status, status())
        controller.selectPeer(43); XCTAssertEqual(disposed, 1); XCTAssertNil(controller.status)
        callbacks[0](status()); XCTAssertNil(controller.status)
        callbacks[1](status(peer: 43)); XCTAssertEqual(controller.status?.peerID, 43)
        controller.setVisible(false); XCTAssertEqual(disposed, 2); XCTAssertNil(controller.status)
        controller.setVisible(true); XCTAssertEqual(callbacks.count, 3)
        controller.bind(accountID: 2) { _ in .single(self.status(account: 2, peer: 43)) }
        XCTAssertEqual(disposed, 3); XCTAssertEqual(controller.status?.accountID, 2)
        callbacks[2](status(peer: 43)); XCTAssertEqual(controller.status?.accountID, 2)
    }
    func testInitialUnavailableRecoversReactivelyAndSelfStaysHidden() {
        let pipe = ValuePipe<TelegramPeerStatus?>(), controller = TelegramPeerStatusController()
        controller.bind(accountID: 1) { _ in pipe.signal() }
        controller.selectPeer(42); controller.setVisible(true)
        let request = controller.requestID
        pipe.putNext(nil); XCTAssertNil(controller.status)
        pipe.putNext(status()); XCTAssertEqual(controller.status, status())
        XCTAssertEqual(controller.requestID, request)
        controller.setVisible(false); pipe.putNext(status()); XCTAssertNil(controller.status)
    }
}

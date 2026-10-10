import XCTest
import Foundation
import Postbox
@testable import MakoshTelegram

@MainActor final class TelegramHistoryReadTests: XCTestCase {
    private final class Provider: TelegramHistoryReadProvider {
        let accountID: Int64
        var requests: [(TelegramHistoryReadTarget, @MainActor (Bool) -> Void)] = []
        var synchronous: Bool?
        init(_ accountID: Int64 = 1) { self.accountID = accountID }
        func apply(_ target: TelegramHistoryReadTarget, completion: @escaping @MainActor (Bool) -> Void) {
            requests.append((target, completion))
            if let synchronous { completion(synchronous) }
        }
    }
    private func target(_ id: Int32, timestamp: Int32 = 100, peer: Int64 = 2, namespace: Int32 = 0, account: Int64 = 1) -> TelegramHistoryReadTarget {
        let peerID = PeerId(namespace: ._internalFromInt32Value(0), id: ._internalFromInt64Value(peer))
        return TelegramHistoryReadTarget(context: TelegramHistoryReadContext(accountID: account,
            chatID: peerID.toInt64(), accountContextID: UUID(), historyWindowID: UUID()),
            index: MessageIndex(id: MessageId(peerId: peerID, namespace: namespace, id: id), timestamp: timestamp))
    }
    func testVisibilityToleranceRequiresFinitePositiveActualIntersection() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(TelegramHistoryReadVisibility.isVisible(row: CGRect(x: 0, y: -10, width: 100, height: 50), viewport: viewport))
        XCTAssertFalse(TelegramHistoryReadVisibility.isVisible(row: CGRect(x: 0, y: -10.01, width: 100, height: 50), viewport: viewport))
        XCTAssertTrue(TelegramHistoryReadVisibility.isVisible(row: CGRect(x: 99, y: 10, width: 20, height: 20), viewport: viewport))
        for row in [CGRect(x: 100, y: 0, width: 10, height: 10), CGRect(x: 0, y: 100, width: 10, height: 10),
                    CGRect(x: 0, y: 0, width: 100, height: 111), CGRect.zero,
                    CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: CGFloat.infinity)] {
            XCTAssertFalse(TelegramHistoryReadVisibility.isVisible(row: row, viewport: viewport))
        }
        XCTAssertTrue(TelegramHistoryReadVisibility.isVisible(row: CGRect(x: 0, y: 0, width: 100, height: 101), viewport: viewport))
        XCTAssertTrue(TelegramHistoryReadVisibility.isVisible(row: CGRect(x: 0, y: -5, width: 100, height: 110), viewport: viewport))
        XCTAssertFalse(TelegramHistoryReadVisibility.isVisible(row: viewport, viewport: .zero))
    }
    func testMonotonicFullIndexAndPeerNamespaceScopes() {
        let controller = TelegramHistoryReadController(), provider = Provider()
        controller.bind(provider)
        let first = target(5)
        XCTAssertTrue(controller.apply(first))
        XCTAssertFalse(controller.apply(first))
        XCTAssertFalse(controller.apply(target(4)))
        provider.requests[0].1(true)
        XCTAssertFalse(controller.apply(first))
        XCTAssertTrue(controller.apply(target(1, timestamp: 101)), "Full MessageIndex orders timestamp before ID")
        XCTAssertTrue(controller.apply(target(1, peer: 3)))
        XCTAssertTrue(controller.apply(target(1, namespace: 77)))
        XCTAssertEqual(provider.requests.count, 4)
    }
    func testFailureReleasesPendingForFutureObservationAndSuccessNeverRegresses() {
        let controller = TelegramHistoryReadController(), provider = Provider(); controller.bind(provider)
        let lower = target(1), higher = target(2)
        XCTAssertTrue(controller.apply(lower)); XCTAssertTrue(controller.apply(higher))
        provider.requests[1].1(true)
        provider.requests[0].1(false)
        XCTAssertFalse(controller.apply(lower)); XCTAssertFalse(controller.apply(higher))
        let latest = target(3)
        XCTAssertTrue(controller.apply(latest)); provider.requests[2].1(false)
        XCTAssertTrue(controller.apply(latest))
    }
    func testAccountGuardRebindAndLateCompletionCannotPoisonNewBinding() {
        let controller = TelegramHistoryReadController(), old = Provider(), fresh = Provider()
        XCTAssertFalse(controller.apply(target(1)))
        controller.bind(old)
        XCTAssertFalse(controller.apply(target(1, account: 9)))
        let pending = target(1); XCTAssertTrue(controller.apply(pending))
        controller.bind(fresh)
        old.requests[0].1(true)
        XCTAssertTrue(controller.apply(pending))
        controller.bind(nil); fresh.requests[0].1(false)
        XCTAssertFalse(controller.apply(target(2)))
    }
    func testSynchronousFailureCanRetryAndSynchronousSuccessDeduplicates() {
        let controller = TelegramHistoryReadController(), provider = Provider(); controller.bind(provider)
        provider.synchronous = false
        let item = target(1)
        XCTAssertTrue(controller.apply(item)); XCTAssertTrue(controller.apply(item))
        provider.synchronous = true
        XCTAssertTrue(controller.apply(item)); XCTAssertFalse(controller.apply(item))
        XCTAssertEqual(provider.requests.count, 3)
    }
}

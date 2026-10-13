import XCTest
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramNotificationBatchPumpTests: XCTestCase {
    private func id(_ number: Int32) -> MessageId { .init(peerId: PeerId(7), namespace: 0, id: number) }
    func testSlowReadRetainsOnlyBoundedUniquePendingIDsAndReportsOverflowOnce() {
        var reads: [[MessageId]] = [], callbacks: [() -> Void] = [], overflows = 0, disposals = 0
        let pump = TelegramNotificationBatchPump(read: { ids in Signal { subscriber in
            reads.append(ids); callbacks.append { subscriber.putCompletion() }
            return ActionDisposable { disposals += 1 }
        } }, next: { _ in }, overflow: { overflows += 1 })
        pump.offer([id(1)]); XCTAssertEqual(reads.count, 1)
        pump.offer(Array(repeating: id(2), count: 2000))
        pump.offer((2...1101).map { id(Int32($0)) })
        pump.offer((2000...3100).map { id(Int32($0)) })
        XCTAssertEqual(reads.count, 1); XCTAssertEqual(overflows, 1)
        guard let complete = callbacks.first else { XCTFail("First native read was not started"); return }
        complete(); XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads.last?.count, 1000)
        XCTAssertEqual(reads.last?.first, id(2)); XCTAssertEqual(reads.last?.last, id(1001))
        pump.dispose(); XCTAssertEqual(disposals, 2)
        pump.offer([id(4000)]); XCTAssertEqual(reads.count, 2)
    }
    func testSynchronousCompletionDoesNotDisposeTheNextReadOrRetainAStuckActiveToken() {
        var reads: [[MessageId]] = [], deliveries = 0
        let pump = TelegramNotificationBatchPump(read: { ids in reads.append(ids); return .single([]) },
            next: { _ in deliveries += 1 }, overflow: { XCTFail("Unexpected overflow") })
        pump.offer([id(1)]); pump.offer([id(2)])
        XCTAssertEqual(reads, [[id(1)],[id(2)]]); XCTAssertEqual(deliveries, 2)
        pump.dispose(); pump.offer([id(3)]); XCTAssertEqual(reads.count, 2)
    }
}

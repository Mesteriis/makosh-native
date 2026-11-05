import Foundation
import MakoshCore
import XCTest
@testable import MakoshTelegram

final class TelegramAIContextProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func message(_ day: Int, _ text: String = "t") -> TelegramAIContextMessage {
        TelegramAIContextMessage(
            authorID: 7, authorName: "Мария", isOutgoing: false, date: now.addingTimeInterval(TimeInterval(-day * 86_400)), text: text,
            isProtected: false)
    }

    func testLatestTakesNewestInDateOrder() {
        let all = [message(1, "b"), message(3, "a"), message(0, "c")]
        XCTAssertEqual(TelegramAIContextProjection.select(all, range: .latest(2), now: now).map(\.text), ["b", "c"])
    }

    func testLastDaysCutsOlder() {
        let all = [message(10, "old"), message(2, "recent"), message(0, "today")]
        XCTAssertEqual(TelegramAIContextProjection.select(all, range: .lastDays(7), now: now).map(\.text), ["recent", "today"])
    }

    func testBetweenIsInclusive() {
        let all = [message(5, "x"), message(3, "from"), message(2, "mid"), message(1, "to"), message(0, "y")]
        let range = AIContextRange.between(now.addingTimeInterval(-3 * 86_400), now.addingTimeInterval(-1 * 86_400))
        XCTAssertEqual(TelegramAIContextProjection.select(all, range: range, now: now).map(\.text), ["from", "mid", "to"])
    }

    func testMediaOnlyGetsPlaceholder() {
        let media = message(0, "")
        XCTAssertEqual(TelegramAIContextProjection.select([media], range: .standard, now: now).first?.text, "[вложение]")
    }
}

import SwiftSignalKit

@MainActor final class TelegramAIContextSignalTests: XCTestCase {
    /// Postbox delivers on its own queue; awaiting from the main actor must not trap.
    func testValueDeliveredOnAnotherQueueReachesTheMainActorCaller() async throws {
        let signal = Signal<Int, NoError> { subscriber in
            DispatchQueue.global().async {
                subscriber.putNext(7)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
        let value = try await telegramAIContextFirst(signal)
        XCTAssertEqual(value, 7)
    }

    func testCompletionWithoutValueThrowsInsteadOfHanging() async {
        let signal = Signal<Int, NoError> { subscriber in
            DispatchQueue.global().async { subscriber.putCompletion() }
            return EmptyDisposable
        }
        do {
            _ = try await telegramAIContextFirst(signal)
            XCTFail("no value")
        } catch {}
    }
}

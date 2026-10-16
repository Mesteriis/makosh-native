import XCTest
@testable import Postbox
import TelegramCore
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramNativeViewProjectionTests: XCTestCase {
    func testNonemptyChatProjectionIsProducedOffMain() async throws {
        let account = try await telegramCallbackAccount(test: self)
        _ = try await telegramDataValue(callbackSeedMessage(account.postbox), test: self)
        let received = expectation(description: "native chat projection")
        let observation = Self.chatPage(account).start(next: { @Sendable page in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(page.chats.first(where: { $0.id == 777 })?.preview, "before")
            received.fulfill()
        })
        defer { observation.dispose() }
        await fulfillment(of: [received], timeout: 10)
    }
    func testNonemptyHistoryProjectionIncludesReadBoundaryOffMain() async throws {
        let account = try await telegramCallbackAccount(test: self)
        _ = try await telegramDataValue(callbackSeedMessage(account.postbox), test: self)
        _ = try await telegramDataValue(Self.loadedHistory(account.postbox), test: self)
        let received = expectation(description: "native history projection")
        let observation = Self.historyPage(account).start(next: { @Sendable page in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(page.messages.first(where: { $0.id == "777:0:1" })?.text, "before")
            XCTAssertEqual(page.readIndexes["777:0:1"]?.id.id, 1)
            received.fulfill()
        })
        defer { observation.dispose() }
        await fulfillment(of: [received], timeout: 10)
    }
    private nonisolated static func chatPage(_ account: Account) -> Signal<TelegramChatPageProjection, NoError> {
        telegramProjectChatPage(account: account, signal: account.viewTracker.tailChatListView(groupId: .root, count: 50))
        |> filter { $0.chats.contains(where: { $0.id == 777 }) } |> take(1)
    }
    private nonisolated static func historyPage(_ account: Account) -> Signal<TelegramHistoryPageProjection, NoError> {
        telegramProjectHistoryPage(account: account, chatID: 777, threadID: nil, index: .upperBound)
        |> filter { $0.messages.contains(where: { $0.id == "777:0:1" }) } |> take(1)
    }
    private nonisolated static func loadedHistory(_ box: Postbox) -> Signal<Void, NoError> {
        box.transaction { transaction in
            // Model a loaded cloud history; the default seed otherwise leaves
            // this cached message in an island behind an unfilled server hole.
            transaction.removeHole(peerId: PeerId(777), threadId: nil, namespace: Namespaces.Message.Cloud,
                space: .everywhere, range: 1...(Int32.max - 1))
        }
    }
}

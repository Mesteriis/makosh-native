import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramComposerReplyTests: XCTestCase {
    private final class Provider: TelegramComposerReplyProvider {
        let accountID: Int64
        var callbacks: [@MainActor (TelegramComposerReply?) -> Void] = []
        var cancelled: [Bool] = []
        var synchronous: TelegramComposerReply?
        init(accountID: Int64 = 1) { self.accountID = accountID }
        func resolve(target: TelegramComposerReplyTarget, chatID: Int64,
                     completion: @escaping @MainActor (TelegramComposerReply?) -> Void) -> Disposable {
            let index = callbacks.count
            callbacks.append(completion); cancelled.append(false)
            if let synchronous { completion(synchronous) }
            return ActionDisposable { MainActor.assumeIsolated { self.cancelled[index] = true } }
        }
    }
    private func reply(account: Int64 = 1, chat: Int64 = 10, message: Int32 = 42,
                       thread: Int64? = nil, allowed: Bool = true) -> TelegramComposerReply {
        let metadata = TelegramMessageActionMetadata(peerID: chat, namespace: 0, messageID: message,
            fingerprint: "synthetic-version", text: "Synthetic target", authorID: account,
            canReply: allowed, canEdit: false, canForward: false, canDeleteLocally: false,
            canDeleteForEveryone: false, threadID: thread)
        return TelegramComposerReply(source: TelegramMessageActionSource(metadata: metadata, accountID: account, chatID: chat), author: "Synthetic")
    }
    func testSynchronousResolutionAndStaleSelectionCallbacks() throws {
        let controller = TelegramComposerReplyController(), provider = Provider()
        controller.bind(provider)
        let first = reply(), second = reply(message: 43)
        controller.select(target: .init(source: first.source), chatID: 10)
        XCTAssertEqual(controller.state, .loading)
        controller.select(target: .init(source: second.source), chatID: 10)
        XCTAssertTrue(provider.cancelled[0])
        provider.callbacks[0](first); XCTAssertEqual(controller.state, .loading)
        provider.callbacks[1](second); XCTAssertEqual(controller.state, .ready(second))
        let synchronous = Provider(); synchronous.synchronous = first
        controller.bind(synchronous); controller.select(target: .init(source: first.source), chatID: 10)
        XCTAssertEqual(controller.state, .ready(first))
        controller.select(target: nil, chatID: nil)
        XCTAssertEqual(controller.state, .none)
    }
    func testForeignIdentityThreadAndDeniedReplyNeverBecomeReady() {
        let target = reply(thread: 9)
        for invalid in [reply(account: 99, thread: 9), reply(chat: 20, thread: 9),
                        reply(message: 99, thread: 9), reply(thread: 10), reply(thread: 9, allowed: false)] {
            let controller = TelegramComposerReplyController(), provider = Provider()
            controller.bind(provider); controller.select(target: .init(source: target.source), chatID: 10)
            provider.callbacks[0](invalid)
            XCTAssertEqual(controller.state, .unavailable)
        }
    }
    func testTimeoutRetryAndRebindRejectOldCallbacks() throws {
        let controller = TelegramComposerReplyController(), provider = Provider(), target = reply()
        controller.bind(provider); controller.select(target: .init(source: target.source), chatID: 10)
        let old = try XCTUnwrap(controller.requestID)
        controller.timeout(requestID: old)
        XCTAssertEqual(controller.state, .unavailable); XCTAssertTrue(provider.cancelled[0])
        controller.retry(); XCTAssertEqual(controller.state, .loading)
        controller.timeout(requestID: old); provider.callbacks[0](target)
        XCTAssertEqual(controller.state, .loading)
        provider.callbacks[1](nil); XCTAssertEqual(controller.state, .unavailable)
        controller.retry()
        controller.bind(Provider(accountID: 99))
        provider.callbacks[2](target); XCTAssertNotEqual(controller.state, .ready(target))
    }
    func testUnresolvedTargetPreventsSendUntilExplicitCancelAndInitialCannotBypassAccount() {
        let controller = TelegramComposerReplyController(), provider = Provider(), target = reply()
        controller.bind(provider)
        controller.select(target: .init(source: target.source), chatID: 10, initial: reply(account: 99))
        XCTAssertEqual(controller.state, .loading); XCTAssertTrue(controller.preventsSend)
        provider.callbacks[0](nil)
        XCTAssertEqual(controller.state, .unavailable); XCTAssertTrue(controller.preventsSend)
        controller.select(target: nil, chatID: 10)
        XCTAssertEqual(controller.state, .none); XCTAssertFalse(controller.preventsSend)
    }

    #if DEBUG
    func testActualSyntheticProviderResolvesCurrentAndOlderTargetsWithoutEmptySearch() {
        let controller = TelegramComposerReplyController()
        controller.bind(TelegramSyntheticComposerReplyProvider())
        for id in [Int32(130), Int32(25)] {
            controller.select(target: .init(peerID: 10001, namespace: 0, messageID: id), chatID: 10001)
            XCTAssertEqual(controller.resolved?.source.messageID, id)
            XCTAssertEqual(controller.resolved?.source.chatID, 10001)
            XCTAssertEqual(controller.resolved?.source.text, "Тестовое сообщение \(id) • диалог 10001")
            XCTAssertFalse(controller.preventsSend)
        }
        controller.select(target: .init(peerID: 10001, namespace: 0, messageID: 999), chatID: 10001)
        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertTrue(controller.preventsSend)
    }
    #endif

}

#if DEBUG
import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramShiftSelectionModelTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private final class Provider: TelegramMessageSelectionRangeProvider {
        let accountID: Int64 = -1
        var requests: [TelegramMessageSelectionRangeRequest] = []
        var completions: [@MainActor ([TelegramMessageActionSource]) -> Void] = []
        let disposalCounter = Counter()
        var disposed: Int { disposalCounter.value }
        var synchronous = false
        func resolve(request: TelegramMessageSelectionRangeRequest,
                     completion: @escaping @MainActor ([TelegramMessageActionSource]) -> Void) -> Disposable {
            requests.append(request); completions.append(completion)
            if synchronous { completion(Self.sources(request)) }
            let counter = disposalCounter
            return ActionDisposable { counter.increment() }
        }
        static func sources(_ request: TelegramMessageSelectionRangeRequest) -> [TelegramMessageActionSource] {
            (request.lowerBound..<request.upperBoundExclusive).map { n in
                .init(accountID: request.accountID, chatID: request.chatID, peerID: request.chatID,
                      namespace: 0, messageID: n, fingerprint: "synthetic-version-1-\(request.chatID)-\(n)",
                      text: "synthetic", canReply: true, canEdit: false, canForward: n != 120,
                      canDeleteLocally: true, canDeleteForEveryone: false)
            }
        }
    }
    private func fixture() -> TelegramModel {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001; return model
    }
    private func messageID(_ value: Int) -> String { "synthetic:10001:\(value)" }
    private func begin(_ model: TelegramModel) throws -> TelegramMessageSelectionSession {
        XCTAssertTrue(model.beginMessageSelection(messageID: messageID(130), contextID: model.messageActionContextID,
            windowID: try XCTUnwrap(model.historyWindowID)))
        return try XCTUnwrap(model.messageSelection.session)
    }
    private func shift(_ model: TelegramModel, _ session: TelegramMessageSelectionSession, _ number: Int) throws {
        XCTAssertTrue(model.toggleMessageSelection(messageID: messageID(number), sessionID: session.id,
            contextID: session.contextID, windowID: try XCTUnwrap(model.historyWindowID), extendingRange: true))
    }
    func testSyntheticCrossPageRangeIncludesProtectedCachedMessageAndPreservesDraft() throws {
        let model = fixture(); model.draft = "ordinary 😀"
        let session = try begin(model); model.loadOlderMessages(); try shift(model, session, 40)
        let range = try XCTUnwrap(model.messageSelection.session)
        XCTAssertEqual(range.count, 91); XCTAssertEqual(range.sources.map(\.messageID), (40...130).map(Int32.init))
        XCTAssertFalse(range.canForward); XCTAssertTrue(range.sources.contains { $0.messageID == 120 && !$0.canForward })
        XCTAssertFalse(model.messageSelection.isResolvingRange)
        XCTAssertFalse(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: session.id, contextID: session.contextID))
        XCTAssertEqual(model.draft, "ordinary 😀"); XCTAssertNil(model.composerForwardIntent)
        try shift(model, session, 40)
        XCTAssertEqual(model.messageSelection.session?.count, 90)
        XCTAssertEqual(model.messageSelection.session?.lastSelectedID?.messageID, 130)
        XCTAssertTrue(model.messageSelection.contains(try XCTUnwrap(range.sources.first { $0.messageID == 41 })))
    }
    func testSyntheticLongRangePartiallyFillsDescendingTo100() throws {
        let model = fixture(), session = try begin(model)
        model.loadOlderMessages(); model.loadOlderMessages(); try shift(model, session, 1)
        let range = try XCTUnwrap(model.messageSelection.session)
        XCTAssertEqual(range.count, 100)
        XCTAssertEqual(range.sources.map(\.messageID), [Int32(1)] + (32...130).map(Int32.init))
        XCTAssertNotNil(model.messageSelection.error); XCTAssertFalse(range.canForward)
    }
    func testPendingRangeCannotStageAndLateCallbacksAfterLifecycleChangesAreIgnored() async throws {
        for change in 0..<4 {
            let model = fixture(), provider = Provider(); model.bindMessageSelectionRangeProvider(provider)
            let session = try begin(model); model.loadOlderMessages(); try shift(model, session, 40)
            XCTAssertEqual(provider.requests.count, 1); XCTAssertTrue(model.messageSelection.isResolvingRange)
            XCTAssertFalse(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: session.id, contextID: session.contextID))
            let request = provider.requests[0]
            switch change {
            case 0: model.showLatestMessages()
            case 1: model.selectedChatID = 10002
            case 2: model.cancelMessageSelection(sessionID: session.id, contextID: session.contextID)
            default:
                XCTAssertTrue(model.toggleMessageSelection(messageID: messageID(41), sessionID: session.id,
                    contextID: session.contextID, windowID: try XCTUnwrap(model.historyWindowID)))
            }
            let before = model.messageSelection.session
            provider.completions[0](Provider.sources(request))
            XCTAssertEqual(model.messageSelection.session, before)
            XCTAssertFalse(model.messageSelection.isResolvingRange); XCTAssertNil(model.composerForwardIntent)
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(provider.disposed, 1)
        }
    }
    func testSynchronousProviderResultAndReturnedDisposableAreHandledOnce() async throws {
        let model = fixture(), provider = Provider(); provider.synchronous = true
        model.bindMessageSelectionRangeProvider(provider)
        let session = try begin(model); model.loadOlderMessages(); try shift(model, session, 40)
        XCTAssertEqual(model.messageSelection.session?.count, 91); XCTAssertFalse(model.messageSelection.isResolvingRange)
        let before = model.messageSelection.session
        provider.completions[0]([]); XCTAssertEqual(model.messageSelection.session, before)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(provider.disposed, 1)
    }
}
#endif

import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramRemotePeerSearchControllerTests: XCTestCase {
    private final class Request: TelegramRemotePeerRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramRemotePeerProvider {
        let accountID: Int64
        var searches: [(String, Request, @MainActor (Result<[TelegramDiscoveredPeer], TelegramRemotePeerError>) -> Void)] = []
        var resolutions: [(Int64, Request, @MainActor (Result<TelegramChat, TelegramRemotePeerError>) -> Void)] = []
        init(_ id: Int64) { accountID = id }
        func search(query: String, receive: @escaping @MainActor (Result<[TelegramDiscoveredPeer], TelegramRemotePeerError>) -> Void) -> any TelegramRemotePeerRequest {
            let r = Request(); searches.append((query,r,receive)); return r
        }
        func resolve(peerID: Int64, receive: @escaping @MainActor (Result<TelegramChat, TelegramRemotePeerError>) -> Void) -> any TelegramRemotePeerRequest {
            let r = Request(); resolutions.append((peerID,r,receive)); return r
        }
    }
    private var alice: TelegramDiscoveredPeer { .init(chat: .init(id: 7, title: "Alice", preview: "", unreadCount: 0), username: "alice") }
    private func waitForSearch(_ p: Provider, count: Int = 1) async throws {
        let clock = ContinuousClock(); let end = clock.now.advanced(by: .seconds(2))
        while p.searches.count < count { guard clock.now < end else { XCTFail("Remote request not admitted"); throw WaitError.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    }
    private enum WaitError: Error { case timeout }
    func testArchiveAndFilteredQueriesDoNotStartRemoteDiscovery() async throws {
        let p = Provider(100); let c = TelegramRemotePeerSearch(); c.bind(p)
        c.search("alice", enabled: false); try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(c.status, .idle); XCTAssertTrue(p.searches.isEmpty)
        c.search("#alice"); try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(c.status, .idle); XCTAssertTrue(p.searches.isEmpty)
    }
    func testSearchFailureIsDifferentFromSuccessfulEmptyAndCanRetry() async throws {
        let p = Provider(100); let c = TelegramRemotePeerSearch(); c.bind(p); c.search("alice")
        try await waitForSearch(p); p.searches[0].2(.failure(.failed))
        XCTAssertEqual(c.status, .failed); XCTAssertTrue(c.results.isEmpty)
        c.retry(); try await waitForSearch(p, count: 2); p.searches[1].2(.success([]))
        XCTAssertEqual(c.status, .ready); XCTAssertTrue(c.results.isEmpty)
    }
    func testQueryReplacementAndRebindRejectLateResultAndOldActivation() async throws {
        let p = Provider(100); let c = TelegramRemotePeerSearch(); c.bind(p); c.search("alice")
        try await waitForSearch(p); let oldContext = c.contextID
        c.search("bob"); p.searches[0].2(.success([alice])); XCTAssertTrue(c.results.isEmpty)
        XCTAssertFalse(c.activate(peerID: 7, contextID: oldContext) { _ in XCTFail("Stale result activated") })
        try await waitForSearch(p, count: 2); c.bind(Provider(200)); p.searches[1].2(.success([alice]))
        XCTAssertTrue(c.results.isEmpty); XCTAssertEqual(c.accountID, 200); XCTAssertEqual(c.status, .idle)
    }
    func testActivationRequiresCurrentResultAndFreshResolutionAndRejectsLateAccount() async throws {
        let p = Provider(100); let c = TelegramRemotePeerSearch(); c.bind(p); c.search("alice")
        try await waitForSearch(p); p.searches[0].2(.success([alice])); let context = c.contextID
        var activated: TelegramChat?
        XCTAssertTrue(c.activate(peerID: 7, contextID: context) { activated = $0 })
        XCTAssertNil(activated); XCTAssertFalse(c.activate(peerID: 7, contextID: context) { _ in XCTFail("Duplicate activation") })
        c.bind(Provider(200)); p.resolutions[0].2(.success(alice.chat)); XCTAssertNil(activated)
        XCTAssertTrue(p.resolutions[0].1.cancelled)
    }
    func testFreshResolutionCannotRetargetSelectedPeerAndSuccessfulResolveUsesFreshTitle() async throws {
        let p = Provider(100); let c = TelegramRemotePeerSearch(); c.bind(p); c.search("alice")
        try await waitForSearch(p); p.searches[0].2(.success([alice])); var activated: TelegramChat?
        XCTAssertTrue(c.activate(peerID: 7, contextID: c.contextID) { activated = $0 })
        p.resolutions[0].2(.success(.init(id: 8, title: "Wrong", preview: "", unreadCount: 0)))
        XCTAssertNil(activated); XCTAssertEqual(c.status, .failed)
        c.retry(); try await waitForSearch(p,count:2); p.searches[1].2(.success([alice]))
        XCTAssertTrue(c.activate(peerID: 7, contextID: c.contextID) { activated = $0 })
        p.resolutions[1].2(.success(.init(id: 7, title: "Alice renamed", preview: "", unreadCount: 0)))
        XCTAssertEqual(activated?.title, "Alice renamed")
    }
}

import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramPrivacyDirectoryTests: XCTestCase {
    private final class Request: TelegramPrivacyRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramPrivacyProvider {
        let accountID: Int64 = 1
        var requests: [(Request, String, [TelegramPrivacyPeerID], @MainActor (Result<TelegramPrivacyPeerDirectory, TelegramPrivacyError>) -> Void)] = []
        func load(receive: @escaping @MainActor (Result<TelegramPrivacySnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest { Request() }
        func apply(_ change: TelegramPrivacyChange, expectedAccountID: Int64, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest { Request() }
        func peers(query: String, include: [TelegramPrivacyPeerID], receive: @escaping @MainActor (Result<TelegramPrivacyPeerDirectory, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
            let r = Request(); requests.append((r, query, include, receive)); return r
        }
    }
    private func response(account: Int64 = 1, peers: [TelegramPrivacyPeer] = [.init(id: .user(7), title: "Synthetic Alice")]) -> TelegramPrivacyPeerDirectory {
        .init(accountID: account, candidates: peers, existing: [], hasMore: false)
    }
    func testNewQueryCancelsOldSearchAndIgnoresLateNames() {
        let c = TelegramPrivacyPeerDirectoryController(), p = Provider(); c.bind(p)
        c.search(query: "Alice", include: [.chat(9)]); c.search(query: "Bob", include: [])
        XCTAssertEqual(p.requests.count, 2); guard p.requests.count == 2 else { return }
        XCTAssertTrue(p.requests[0].0.cancelled); XCTAssertEqual(p.requests[1].1, "Bob")
        p.requests[0].3(.success(response())); XCTAssertNil(c.result)
        p.requests[1].3(.success(response(peers: [.init(id: .user(8), title: "Synthetic Bob")])));
        XCTAssertEqual(c.result?.candidates.map(\.id), [.user(8)]); XCTAssertEqual(c.status, .ready)
        c.close(); XCTAssertNil(c.result); p.requests[1].3(.success(response())); XCTAssertNil(c.result)
    }
    func testWrongAccountDuplicatesAndUnrequestedExistingNamesFailClosed() {
        let c = TelegramPrivacyPeerDirectoryController(), p = Provider(); c.bind(p)
        let duplicate = TelegramPrivacyPeer(id: .user(7), title: "Synthetic")
        for value in [response(account: 2), response(peers: [duplicate, duplicate]),
                      .init(accountID: 1, candidates: [], existing: [duplicate], hasMore: false)] {
            c.search(query: "", include: []); XCTAssertEqual(p.requests.count, 1); guard p.requests.count == 1 else { return }
            p.requests.removeFirst().3(.success(value)); XCTAssertEqual(c.status, .failed); XCTAssertNil(c.result)
        }
    }
    func testSyntheticWorkspaceCanAddMoveAndRemoveExceptionsWithoutAnAudienceChange() throws {
        let model = TelegramModel.syntheticPreview(), c = model.accountPrivacy; c.open()
        let old = try XCTUnwrap(c.snapshot?.settings[.presence])
        let updated = try XCTUnwrap(old.replacingExceptions(.deny, peers: [.user(7), .chat(9)]))
        XCTAssertTrue(c.apply(.init(expected: old, replacement: updated), contextID: c.contextID))
        XCTAssertEqual(c.snapshot?.settings[.presence]?.rules, [.denyUsers([7]), .denyChats([9]), .contacts, .premium])
    }
}

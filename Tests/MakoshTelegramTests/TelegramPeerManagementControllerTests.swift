import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramPeerManagementControllerTests: XCTestCase {
    private final class Request: TelegramPeerManagementRequest {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private final class Provider: TelegramPeerManagementProvider {
        var accountID: Int64 = 1
        struct Read {
            let peerID: Int64, category: TelegramPeerMemberCategory?, query: String, offset: Int32
            let receive: @MainActor (Result<TelegramPeerMemberPage, TelegramPeerManagementError>) -> Void
            let request: Request
        }
        var reads: [Read] = []
        var changes: [TelegramPeerChange] = []
        var callbacks: [@MainActor (Result<Void, TelegramPeerManagementError>) -> Void] = []
        var requests: [Request] = []
        var synchronous = false
        func load(peerID: Int64, category: TelegramPeerMemberCategory?, query: String, offset: Int32,
            receive: @escaping @MainActor (Result<TelegramPeerMemberPage, TelegramPeerManagementError>) -> Void) -> any TelegramPeerManagementRequest {
            let request = Request()
            reads.append(.init(peerID: peerID, category: category, query: query, offset: offset, receive: receive, request: request))
            if synchronous { receive(.success(TelegramPeerManagementControllerTests.page(peerID: peerID))) }
            return request
        }
        func apply(peerID: Int64, change: TelegramPeerChange,
            receive: @escaping @MainActor (Result<Void, TelegramPeerManagementError>) -> Void) -> any TelegramPeerManagementRequest {
            changes.append(change); callbacks.append(receive)
            let request = Request(); requests.append(request); return request
        }
    }
    private static func member(_ id: Int64) -> TelegramPeerMember {
        .init(id: id, title: "Synthetic \(id)", role: .member, adminRights: 0, bannedRights: 0, untilDate: 0, rank: nil, editable: true)
    }
    private static func page(peerID: Int64 = 42, ids: [Int64] = [], next: Int32? = nil, accountID: Int64 = 1) -> TelegramPeerMemberPage {
        .init(snapshot: .init(accountID: accountID, peerID: peerID, title: "Synthetic", about: nil, basicGroup: false,
            canEditInfo: true, canViewMembers: true, canViewAdministrators: true, canRestrict: true, canPromote: true, grantableRights: 1),
            members: ids.map(member), nextOffset: next)
    }
    func testContextChangeCancelsReadAndRejectsLateAccountAndPeerResults() throws {
        let value = TelegramPeerManagementController(), provider = Provider()
        value.bind(provider); value.open(peerID: 42)
        XCTAssertEqual(provider.reads.count, 1); guard provider.reads.count == 1 else { return }
        value.open(peerID: 43); XCTAssertTrue(provider.reads[0].request.cancelled)
        provider.reads[0].receive(.success(Self.page()))
        XCTAssertNil(value.snapshot)
        provider.reads[1].receive(.success(Self.page(peerID: 43, accountID: 2)))
        XCTAssertNil(value.snapshot); XCTAssertEqual(value.status, .failed)
        value.refresh(); provider.reads[2].receive(.success(Self.page(peerID: 43)))
        XCTAssertEqual(value.snapshot?.peerID, 43)
        value.close(); provider.reads[2].receive(.success(Self.page(peerID: 43)))
        XCTAssertNil(value.snapshot); XCTAssertEqual(value.status, .idle)
    }
    func testPaginationPreservesRawOffsetDeduplicatesAndRejectsLateQuery() throws {
        let value = TelegramPeerManagementController(), provider = Provider(); provider.synchronous = true
        value.bind(provider); value.open(peerID: 42); provider.synchronous = false
        XCTAssertNotNil(value.snapshot); guard value.snapshot != nil else { return }
        value.show(.members)
        provider.reads[1].receive(.success(Self.page(ids: [2,3], next: 64)))
        value.loadMore(); XCTAssertEqual(provider.reads[2].offset, 64)
        provider.reads[2].receive(.success(Self.page(ids: [3,4])))
        XCTAssertEqual(value.members.map(\.id), [2,3,4]); XCTAssertFalse(value.canLoadMore)
        value.show(.members, query: "  Alice  "); XCTAssertEqual(provider.reads[3].query, "Alice")
        provider.reads[2].receive(.success(Self.page(ids: [9])))
        XCTAssertTrue(value.members.isEmpty)
        provider.reads[3].receive(.failure(.failed)); XCTAssertEqual(value.status, .failed)
        value.refresh(); XCTAssertEqual(provider.reads[4].offset, 0)
    }
    func testMutationHasSingleAdmissionAndTimeoutNeverResendsOrAcceptsLateAck() throws {
        let value = TelegramPeerManagementController(), provider = Provider(); provider.synchronous = true
        value.bind(provider); value.open(peerID: 42)
        let change = TelegramPeerChange.title(previous: "Synthetic", value: "New")
        XCTAssertTrue(value.apply(change, contextID: value.contextID)); guard !provider.callbacks.isEmpty else { return }
        XCTAssertFalse(value.apply(change, contextID: value.contextID)); XCTAssertEqual(provider.changes.count, 1)
        value.timeoutMutation(); XCTAssertTrue(provider.requests[0].cancelled)
        XCTAssertEqual(value.mutationStatus, .uncertain)
        XCTAssertFalse(value.apply(change, contextID: value.contextID))
        provider.callbacks[0](.success(())); XCTAssertEqual(value.mutationStatus, .uncertain)
        XCTAssertEqual(provider.changes.count, 1)
        value.close(); value.open(peerID: 42); XCTAssertEqual(value.mutationStatus, .uncertain)
        value.refresh(); XCTAssertEqual(value.mutationStatus, .idle)
        XCTAssertFalse(value.apply(change, contextID: UUID()))
    }
    func testUnknownParticipantAndInvalidChangeNeverReachProvider() {
        let value = TelegramPeerManagementController(), provider = Provider(); provider.synchronous = true
        value.bind(provider); value.open(peerID: 42)
        XCTAssertFalse(value.apply(.administrator(member: Self.member(8), rights: 1, rank: ""), contextID: value.contextID))
        XCTAssertFalse(value.apply(.title(previous: "Stale", value: "New"), contextID: value.contextID))
        XCTAssertTrue(provider.changes.isEmpty)
    }
    func testTransportAndServerErrorsRemainUncertainWhileExplicitRPCRejectionsCanBeRetried() {
        for code: Int32 in [-500, -1, 0, 200, 500, 503] { XCTAssertEqual(telegramPeerManagementRPCError(code: code), .uncertain) }
        for code: Int32 in [400, 401, 403, 420, 499] { XCTAssertEqual(telegramPeerManagementRPCError(code: code), .failed) }
        let value = TelegramPeerManagementController(), provider = Provider(); provider.synchronous = true
        value.bind(provider); value.open(peerID: 42)
        let change = TelegramPeerChange.title(previous: "Synthetic", value: "New")
        XCTAssertTrue(value.apply(change, contextID: value.contextID)); guard !provider.callbacks.isEmpty else { return }
        provider.callbacks[0](.failure(.uncertain))
        XCTAssertEqual(value.mutationStatus, .uncertain)
        XCTAssertFalse(value.apply(change, contextID: value.contextID))
        value.close(); value.open(peerID: 42); XCTAssertEqual(value.mutationStatus, .uncertain)
    }

}

import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramBlockedUsersControllerTests: XCTestCase {
    func testProfileActionRequiresCurrentUserProfileAndBlockedAccountContext() throws {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001; model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Synthetic profile required") }
        model.accountBlockedUsers.open()
        XCTAssertNotNil(model.blockedUserChange(profile, contextID: model.contactProfileContextID))
        XCTAssertNil(model.blockedUserChange(profile, contextID: UUID()))
        model.selectedChatID = 10002
        XCTAssertNil(model.blockedUserChange(profile, contextID: model.contactProfileContextID))
    }
    func testSyntheticWorkspaceBlocksAndUnblocksWithoutOpeningAnAccount() throws {
        let model = TelegramModel.syntheticPreview(), c = model.accountBlockedUsers; c.open()
        XCTAssertEqual(c.snapshot?.accountID, -1)
        let change = try XCTUnwrap(c.change(userID: 7, title: "Synthetic Alice"))
        XCTAssertFalse(change.wasBlocked); XCTAssertTrue(c.apply(change))
        XCTAssertEqual(c.snapshot?.users.map(\.id), [7,8,99])
        let unblock = try XCTUnwrap(c.change(userID: 7, title: "Synthetic Alice"))
        XCTAssertTrue(unblock.wasBlocked); XCTAssertTrue(c.apply(unblock))
        XCTAssertEqual(c.snapshot?.users.map(\.id), [8,99]); XCTAssertTrue(model.isSyntheticPreview)
    }
    private final class Request: TelegramPrivacyRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramBlockedUsersProvider {
        let accountID: Int64
        init(_ id: Int64 = 1) { accountID = id }
        var reads: [(Request, @MainActor (Result<TelegramBlockedUsersSnapshot, TelegramPrivacyError>) -> Void)] = []
        var writes: [(Request, TelegramBlockedUserChange, @MainActor (Result<Void, TelegramPrivacyError>) -> Void)] = []
        func load(receive: @escaping @MainActor (Result<TelegramBlockedUsersSnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest { let r = Request(); reads.append((r,receive)); return r }
        func apply(_ change: TelegramBlockedUserChange, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest { let r = Request(); writes.append((r,change,receive)); return r }
    }
    private func loaded() throws -> (TelegramBlockedUsersController, Provider) {
        let c = TelegramBlockedUsersController(), p = Provider(); c.bind(p); c.open()
        XCTAssertEqual(p.reads.count, 1)
        let read = try XCTUnwrap(p.reads.first)
        read.1(.success(.init(accountID: 1, users: [.init(id: 7, title: "Synthetic Alice")])))
        return (c,p)
    }
    func testConfirmedUnblockReloadsWithoutOptimisticRemoval() throws {
        let (c,p) = try loaded(), change = try XCTUnwrap(c.change(userID: 7, title: "Synthetic Alice"))
        XCTAssertTrue(change.wasBlocked); XCTAssertTrue(c.apply(change)); XCTAssertFalse(c.apply(change))
        XCTAssertEqual(c.snapshot?.users.map(\.id), [7]); XCTAssertEqual(p.writes.count, 1)
        let write = try XCTUnwrap(p.writes.first); write.2(.success(()))
        XCTAssertEqual(c.mutationStatus, .saved); XCTAssertEqual(p.reads.count, 2)
        p.reads.last?.1(.success(.init(accountID: 1, users: [])))
        XCTAssertEqual(c.snapshot?.users, [])
    }
    func testRefreshAndRebindingInvalidateIdenticalConfirmationAndLateRead() throws {
        let (c,p) = try loaded(), change = try XCTUnwrap(c.change(userID: 7, title: "Synthetic Alice"))
        c.refresh(); p.reads.last?.1(.success(.init(accountID: 1, users: [.init(id: 7, title: "Synthetic Alice")])))
        XCTAssertFalse(c.apply(change)); XCTAssertTrue(p.writes.isEmpty)
        c.bind(Provider(2)); c.open(); p.reads[0].1(.success(.init(accountID: 1, users: [])))
        XCTAssertNil(c.snapshot); XCTAssertFalse(c.apply(change))
    }
    func testUncertaintySurvivesClosingAndBlocksResendUntilExplicitReconciliation() throws {
        let (c,p) = try loaded(), change = try XCTUnwrap(c.change(userID: 7, title: "Synthetic Alice"))
        XCTAssertTrue(c.apply(change)); c.timeoutMutation(); p.writes.first?.2(.success(()))
        XCTAssertEqual(c.mutationStatus, .uncertain); XCTAssertFalse(c.apply(change))
        c.close(); c.open(); p.reads.last?.1(.success(.init(accountID: 1, users: [])))
        XCTAssertEqual(c.mutationStatus, .uncertain); XCTAssertNil(c.change(userID: 8, title: "Synthetic Bob"))
        c.refresh(); p.reads.last?.1(.success(.init(accountID: 1, users: [])))
        XCTAssertEqual(c.mutationStatus, .idle); XCTAssertEqual(p.writes.count, 1)
        XCTAssertFalse(try XCTUnwrap(c.change(userID: 8, title: "Synthetic Bob")).wasBlocked)
    }
    func testWrongAccountDuplicateAndInvalidSnapshotsCannotEnableActions() throws {
        for snapshot in [TelegramBlockedUsersSnapshot(accountID: 2, users: []), .init(accountID: 1, users: [.init(id: 7,title: "A"), .init(id: 7,title: "A")]), .init(accountID: 1, users: [.init(id: 0,title: "A")]), .init(accountID: 1, users: [.init(id: Int64.max,title: "A")])] {
            let c = TelegramBlockedUsersController(), p = Provider(); c.bind(p); c.open()
            let read = try XCTUnwrap(p.reads.first); read.1(.success(snapshot))
            XCTAssertEqual(c.status, .failed); XCTAssertNil(c.change(userID: 7, title: "A"))
        }
    }
    func testRawUserIDCannotBypassEncodedAccountSelfGuard() throws {
        let c = TelegramBlockedUsersController(), p = Provider(34_359_738_375); c.bind(p); c.open()
        let read = try XCTUnwrap(p.reads.first); read.1(.success(.init(accountID: 34_359_738_375, users: [])))
        XCTAssertNil(c.change(userID: 4_294_967_303, title: "Synthetic Self"))
        XCTAssertNil(c.change(userID: Int64.max, title: "Invalid"))
    }
}

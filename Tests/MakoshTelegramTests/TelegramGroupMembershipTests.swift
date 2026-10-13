import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramGroupMembershipTests: XCTestCase {
    private let peerID: Int64 = 4_294_967_306
    private func snapshot(manage: Bool = true, creator: Bool = true) -> TelegramGroupMembershipSnapshot {
        .init(accountID: 101, peerID: peerID, title: "Synthetic group", basic: true, isCreator: creator,
            canInvite: true, canManageLinks: manage, canRequests: manage, canHistory: false)
    }
    private func link(_ n: Int = 1, revoked: Bool = false) -> TelegramGroupInviteLink {
        .init(link: "https://t.me/+Synthetic\(n)", adminID: 101, date: Int32(1000-n), title: "Link \(n)",
            expireDate: nil, usageLimit: nil, usage: 0, requested: 0, requiresApproval: false, revoked: revoked,
            permanent: false, paid: false, origin: nil)
    }
    private func open(_ controller: TelegramGroupMembershipController, _ provider: GroupProvider) {
        controller.bind(provider); controller.open(peerID: peerID)
        provider.reads[0].receive(.success(.init(snapshot: snapshot())))
    }
    func testInvalidNativeIdentitiesAndUnsafeLinksNeverAuthorizeChanges() {
        XCTAssertTrue(snapshot().isValid)
        XCTAssertTrue(link().isValid)
        for raw in ["http://t.me/+Synthetic", "https://evil.invalid/+Synthetic", "https://t.me/+Synthetic?secret=1", "https://u:p@t.me/+Synthetic", "https://t.me/+Synthetic\n"] {
            XCTAssertFalse(telegramValidGroupInviteURL(raw))
        }
        XCTAssertFalse(TelegramGroupMembershipSnapshot(accountID: 0, peerID: peerID, title: "Group", basic: true,
            isCreator: true, canInvite: true, canManageLinks: true, canRequests: true, canHistory: false).isValid)
    }
    func testCreateLinkRequiresFinitePositiveLimitsAndNoPaidParameters() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(TelegramGroupInviteDraft(title: "QA", expireDate: 2000, usageLimit: 2, requiresApproval: false).isValid(now: now))
        XCTAssertFalse(TelegramGroupInviteDraft(title: String(repeating: "x", count: 33), expireDate: nil, usageLimit: nil, requiresApproval: false).isValid(now: now))
        XCTAssertFalse(TelegramGroupInviteDraft(title: "QA", expireDate: 999, usageLimit: nil, requiresApproval: false).isValid(now: now))
        XCTAssertFalse(TelegramGroupInviteDraft(title: "QA", expireDate: nil, usageLimit: 0, requiresApproval: false).isValid(now: now))
        XCTAssertFalse(TelegramGroupInviteDraft(title: "QA", expireDate: nil, usageLimit: 1, requiresApproval: true).isValid(now: now))
    }
    func testStaleReadCannotPublishAfterCloseOrAccountReplacement() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController()
        controller.bind(provider); controller.open(peerID: peerID); controller.close()
        provider.reads[0].receive(.success(.init(snapshot: snapshot())))
        XCTAssertNil(controller.snapshot)
        controller.bind(GroupProvider(accountID: 102)); controller.open(peerID: peerID)
        provider.reads[0].receive(.success(.init(snapshot: snapshot())))
        XCTAssertNil(controller.snapshot)
    }
    func testPageRightsAndWrongAccountResponseFailClosed() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController()
        controller.bind(provider); controller.open(peerID: peerID)
        provider.reads[0].receive(.success(.init(snapshot: snapshot(manage: false, creator: false))))
        XCTAssertFalse(controller.show(.activeLinks)); XCTAssertFalse(controller.show(.history))
        XCTAssertEqual(controller.page, .overview)
        XCTAssertFalse(controller.apply(.create(.init(title: "QA", expireDate: nil, usageLimit: nil, requiresApproval: false)),
            basis: snapshot(), contextID: controller.contextID))
        XCTAssertTrue(provider.writes.isEmpty)
    }
    func testFailedRefreshKeepsRowsAndRevokesMutationAdmission() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.show(.activeLinks))
        provider.reads[1].receive(.success(.init(snapshot: snapshot(), links: [link()])))
        controller.refresh(); provider.reads[2].receive(.failure(.failed))
        XCTAssertEqual(controller.links, [link()]); XCTAssertEqual(controller.status, .failed)
        XCTAssertFalse(controller.apply(.revoke(link()), basis: snapshot(), contextID: controller.contextID))
    }
    func testDuplicateOrForeignPageCannotPartiallyReplaceCurrentList() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.show(.activeLinks))
        provider.reads[1].receive(.success(.init(snapshot: snapshot(), links: [link(), link()])))
        XCTAssertEqual(controller.status, .failed); XCTAssertTrue(controller.links.isEmpty)
    }
    func testPaginationUsesExactAdvancingNativeCursor() throws {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.show(.activeLinks))
        let first = (1...50).map { link($0) }
        let cursor = TelegramGroupMembershipCursor.links(date: 950, link: "https://t.me/+Synthetic50", seen: 50)
        provider.reads[1].receive(.success(.init(snapshot: snapshot(), links: first, next: cursor)))
        XCTAssertTrue(controller.canLoadMore); controller.loadMore()
        XCTAssertEqual(provider.reads[2].cursor, cursor)
        provider.reads[2].receive(.success(.init(snapshot: snapshot(), links: [link(51)], next: cursor)))
        XCTAssertEqual(controller.status, .failed); XCTAssertEqual(controller.links.count, 50)
    }
    func testShortNativeLinkPageCanContinueWithItsExactCursor() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.show(.activeLinks))
        let cursor = TelegramGroupMembershipCursor.links(date: 998, link: "https://t.me/+Synthetic2", seen: 2)
        provider.reads[1].receive(.success(.init(snapshot: snapshot(), links: [link(1), link(2)], next: cursor)))
        XCTAssertEqual(controller.status, .ready); XCTAssertTrue(controller.canLoadMore)
    }
    func testShortNativeRequestPageCanContinueWithItsExactCursor() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.show(.requests))
        let row = TelegramGroupJoinRequest(id: 7, title: "Synthetic Alice", username: nil, date: 100, about: nil, origin: nil)
        provider.reads[1].receive(.success(.init(snapshot: snapshot(), requests: [row], next: .requests(date: 100, userID: 7, seen: 1))))
        XCTAssertEqual(controller.status, .ready); XCTAssertTrue(controller.canLoadMore)
    }
    func testRevokeRequiresCurrentListedLinkAndFrozenConfirmation() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.show(.activeLinks))
        provider.reads[1].receive(.success(.init(snapshot: snapshot(), links: [link()])))
        XCTAssertFalse(controller.apply(.revoke(link(2)), basis: snapshot(), contextID: controller.contextID))
        XCTAssertFalse(controller.apply(.revoke(link()), basis: snapshot(), contextID: UUID()))
        XCTAssertTrue(controller.apply(.revoke(link()), basis: snapshot(), contextID: controller.contextID))
        XCTAssertEqual(provider.writes.count, 1); XCTAssertEqual(controller.phase, .validating)
        XCTAssertFalse(controller.apply(.revoke(link()), basis: snapshot(), contextID: controller.contextID))
    }
    func testCommitTimeoutIsUncertainAndReopenDoesNotClearBarrier() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        let change = TelegramGroupMembershipChange.create(.init(title: "QA", expireDate: nil, usageLimit: nil, requiresApproval: false))
        XCTAssertTrue(controller.apply(change, basis: snapshot(), contextID: controller.contextID))
        XCTAssertTrue(provider.writes[0].receive(.committing)); controller.timeoutMutation()
        XCTAssertEqual(controller.phase, .uncertain)
        controller.close(); controller.open(peerID: peerID); provider.reads[1].receive(.success(.init(snapshot: snapshot())))
        XCTAssertEqual(controller.phase, .uncertain)
        XCTAssertFalse(controller.apply(change, basis: snapshot(), contextID: controller.contextID))
        controller.refresh(); provider.reads[2].receive(.success(.init(snapshot: snapshot())))
        XCTAssertEqual(controller.phase, .idle)
    }
    func testCancelValidationRejectsLateCommitWithoutUnknownWrite() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.apply(.create(.init(title: "QA", expireDate: nil, usageLimit: nil, requiresApproval: false)), basis: snapshot(), contextID: controller.contextID))
        controller.cancelValidation(); XCTAssertFalse(provider.writes[0].receive(.committing))
        XCTAssertEqual(controller.phase, .idle)
    }
    func testWrongReceiptCannotPublishSuccess() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.show(.activeLinks)); provider.reads[1].receive(.success(.init(snapshot: snapshot(), links: [link()])))
        XCTAssertTrue(controller.apply(.revoke(link()), basis: snapshot(), contextID: controller.contextID))
        XCTAssertTrue(provider.writes[0].receive(.committing))
        XCTAssertTrue(provider.writes[0].receive(.saved(.init(accountID: 101, peerID: peerID, result: .revoked("https://t.me/+Wrong")))))
        XCTAssertEqual(controller.phase, .uncertain)
    }
    func testCreatedLinkOpensOwnActiveListEvenFromAnotherOwnersRevokedList() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.show(.revokedLinks))
        let creator = TelegramGroupLinkCreator(id: 102, title: "Synthetic administrator", active: 1, revoked: 0)
        provider.reads[1].receive(.success(.init(snapshot: snapshot(), creators: [creator])))
        XCTAssertTrue(controller.selectOwner(102))
        provider.reads[2].receive(.success(.init(snapshot: snapshot(), creators: [creator])))
        let draft = TelegramGroupInviteDraft(title: "Link 1", expireDate: nil, usageLimit: nil, requiresApproval: false)
        XCTAssertTrue(controller.apply(.create(draft), basis: snapshot(), contextID: controller.contextID))
        XCTAssertTrue(provider.writes[0].receive(.committing))
        XCTAssertTrue(provider.writes[0].receive(.saved(.init(accountID: 101, peerID: peerID, result: .created(link())))))
        XCTAssertEqual(controller.page, .activeLinks); XCTAssertEqual(controller.ownerID, 101)
        XCTAssertEqual(controller.lastCreatedLink, link())
    }
    func testJoinDecisionRequiresTheExactLoadedRequest() {
        let provider = GroupProvider(), controller = TelegramGroupMembershipController(); open(controller, provider)
        XCTAssertTrue(controller.show(.requests))
        let request = TelegramGroupJoinRequest(id: 7, title: "Synthetic Alice", username: "alice", date: 100, about: "QA", origin: nil)
        provider.reads[1].receive(.success(.init(snapshot: snapshot(), requests: [request])))
        let other = TelegramGroupJoinRequest(id: 8, title: "Synthetic Bob", username: "bob", date: 100, about: "QA", origin: nil)
        XCTAssertFalse(controller.apply(.request(other, approve: true), basis: snapshot(), contextID: controller.contextID))
        XCTAssertTrue(controller.apply(.request(request, approve: false), basis: snapshot(), contextID: controller.contextID))
    }
}
@MainActor private final class GroupRequest: TelegramGroupMembershipRequest { func cancel() {} }
@MainActor private final class GroupProvider: TelegramGroupMembershipProvider {
    let accountID: Int64
    struct Read { let cursor: TelegramGroupMembershipCursor?; let receive: @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void }
    struct Write { let receive: @MainActor (TelegramGroupMembershipEvent) -> Bool }
    var reads: [Read] = [], writes: [Write] = []
    init(accountID: Int64 = 101) { self.accountID = accountID }
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?, receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest {
        reads.append(.init(cursor: cursor, receive: receive)); return GroupRequest()
    }
    func apply(basis: TelegramGroupMembershipSnapshot, change: TelegramGroupMembershipChange, receive: @escaping @MainActor (TelegramGroupMembershipEvent) -> Bool) -> any TelegramGroupMembershipRequest {
        writes.append(.init(receive: receive)); return GroupRequest()
    }
}

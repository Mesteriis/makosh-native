import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramPrivacyControllerTests: XCTestCase {
    static func snapshot(account: Int64 = 1) -> TelegramPrivacySnapshot {
        .init(accountID: account, settings: Dictionary(uniqueKeysWithValues: TelegramPrivacyKind.allCases.map { ($0, TelegramPrivacyTests.setting([.contacts], kind: $0)) }))
    }
    func testSyntheticWorkspacePrivacyChangesWithoutOpeningAnAccount() throws {
        let model = TelegramModel.syntheticPreview()
        model.accountPrivacy.open()
        let snapshot = try XCTUnwrap(model.accountPrivacy.snapshot)
        XCTAssertEqual(snapshot.accountID, -1); XCTAssertEqual(snapshot.settings.count, 10)
        let old = try XCTUnwrap(snapshot.settings[.presence])
        XCTAssertTrue(model.accountPrivacy.apply(.init(expected: old, audience: .nobody), contextID: model.accountPrivacy.contextID))
        XCTAssertEqual(model.accountPrivacy.snapshot?.settings[.presence]?.audience, .nobody)
        XCTAssertEqual(model.accountPrivacy.snapshot?.settings[.presence]?.rules.filter { !$0.isBase }, [.allowUsers([7]), .denyChats([9]), .premium])
        XCTAssertTrue(model.isSyntheticPreview)
    }
    func testAcknowledgementFeedbackBelongsOnlyToTheChangedPrivacyCategory() throws {
        let model = TelegramModel.syntheticPreview(), c = model.accountPrivacy
        c.open(); let old = try XCTUnwrap(c.snapshot?.settings[.presence])
        XCTAssertTrue(c.apply(.init(expected: old, audience: .nobody), contextID: c.contextID))
        XCTAssertEqual(c.mutationStatus, .saved)
        XCTAssertEqual(c.mutationStatus(for: .presence), .saved)
        XCTAssertEqual(c.mutationStatus(for: .phoneNumber), .idle)
        XCTAssertEqual(c.mutationStatus(for: .callP2P), .idle)
    }
    private final class Request: TelegramPrivacyRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramPrivacyProvider {
        let accountID: Int64
        init(_ id: Int64 = 1) { accountID = id }
        var reads: [(Request, @MainActor (Result<TelegramPrivacySnapshot, TelegramPrivacyError>) -> Void)] = []
        var writes: [(Request, TelegramPrivacyChange, @MainActor (Result<Void, TelegramPrivacyError>) -> Void)] = []
        func load(receive: @escaping @MainActor (Result<TelegramPrivacySnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
            let r = Request(); reads.append((r, receive)); return r
        }
        func apply(_ change: TelegramPrivacyChange, expectedAccountID: Int64, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
            XCTAssertEqual(expectedAccountID, accountID)
            let r = Request(); writes.append((r, change, receive)); return r
        }
    }
    func testRebindingRejectsLateResultsWrongAccountAndStaleConfirmation() throws {
        let c = TelegramPrivacyController(), p = Provider(), other = Provider(2)
        c.bind(p); c.open(); XCTAssertEqual(p.reads.count, 1); guard p.reads.count == 1 else { return }
        p.reads[0].1(.success(Self.snapshot()))
        let context = c.contextID
        let change = TelegramPrivacyChange(expected: TelegramPrivacyTests.setting([.contacts]), audience: .nobody)
        XCTAssertTrue(c.apply(change, contextID: context))
        c.bind(other); c.open(); XCTAssertTrue(p.writes[0].0.cancelled)
        p.writes[0].2(.success(())); p.reads[0].1(.success(Self.snapshot()))
        XCTAssertNil(c.snapshot); XCTAssertFalse(c.apply(change, contextID: context))
        other.reads[0].1(.success(Self.snapshot()))
        XCTAssertEqual(c.status, .failed); XCTAssertNil(c.snapshot)
    }
    func testRefreshInvalidatesDraftAndAcknowledgementReloadsWithoutOptimisticChanges() throws {
        let c = TelegramPrivacyController(), p = Provider()
        c.bind(p); c.open(); XCTAssertEqual(p.reads.count, 1); guard p.reads.count == 1 else { return }
        p.reads[0].1(.success(Self.snapshot())); let context = c.contextID
        let change = TelegramPrivacyChange(expected: TelegramPrivacyTests.setting([.contacts]), audience: .nobody)
        c.refresh(); p.reads[1].1(.success(Self.snapshot()))
        XCTAssertFalse(c.apply(change, contextID: context))
        XCTAssertTrue(c.apply(change, contextID: c.contextID)); guard p.writes.count == 1 else { return }
        XCTAssertEqual(c.snapshot?.settings[.presence]?.audience, .contacts)
        XCTAssertFalse(c.apply(change, contextID: c.contextID))
        p.writes[0].2(.success(())); XCTAssertEqual(c.mutationStatus, .saved)
        var updated = Self.snapshot().settings; updated[.presence] = TelegramPrivacyTests.setting([.nobody])
        p.reads[2].1(.success(.init(accountID: 1, settings: updated)))
        XCTAssertEqual(c.snapshot?.settings[.presence]?.audience, .nobody)
        XCTAssertFalse(c.apply(change, contextID: c.contextID))
    }
    func testUncertainWriteSurvivesCloseAndRequiresExplicitRefreshWithoutResending() throws {
        let c = TelegramPrivacyController(), p = Provider()
        c.bind(p); c.open(); XCTAssertEqual(p.reads.count, 1); guard p.reads.count == 1 else { return }
        p.reads[0].1(.success(Self.snapshot()))
        let change = TelegramPrivacyChange(expected: TelegramPrivacyTests.setting([.contacts]), audience: .nobody)
        XCTAssertTrue(c.apply(change, contextID: c.contextID)); guard p.writes.count == 1 else { return }
        XCTAssertEqual(c.mutationStatus(for: .phoneNumber), .saving)
        c.timeoutMutation(); p.writes[0].2(.success(())); XCTAssertEqual(c.mutationStatus, .uncertain)
        XCTAssertEqual(c.mutationStatus(for: .phoneNumber), .uncertain)
        c.close(); c.open(); p.reads[1].1(.success(Self.snapshot()))
        XCTAssertEqual(c.mutationStatus, .uncertain); XCTAssertFalse(c.apply(change, contextID: c.contextID))
        c.refresh(); p.reads[2].1(.success(Self.snapshot()))
        XCTAssertEqual(c.mutationStatus, .idle); XCTAssertEqual(p.writes.count, 1)
    }
    func testIncompleteSnapshotCannotEnablePrivacyWrites() {
        let c = TelegramPrivacyController(), p = Provider()
        c.bind(p); c.open(); XCTAssertEqual(p.reads.count, 1); guard p.reads.count == 1 else { return }
        p.reads[0].1(.success(.init(accountID: 1, settings: [.presence: TelegramPrivacyTests.setting()])))
        XCTAssertEqual(c.status, .failed); XCTAssertNil(c.snapshot)
    }
}

import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramGlobalPrivacyControllerTests: XCTestCase {
    final class Request: TelegramPrivacyRequest { var cancelled = false; func cancel() { cancelled = true } }
    final class Provider: TelegramPrivacyProvider {
        let accountID: Int64
        var reads: [(Request, @MainActor (Result<TelegramPrivacySnapshot, TelegramPrivacyError>) -> Void)] = []
        var globalWrites: [(Request, TelegramGlobalPrivacyChange, @MainActor (Result<Void, TelegramPrivacyError>) -> Void)] = []
        var selectiveWrites = 0
        init(_ accountID: Int64 = 1) { self.accountID = accountID }
        func load(receive: @escaping @MainActor (Result<TelegramPrivacySnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest { let r = Request(); reads.append((r, receive)); return r }
        func apply(_ change: TelegramPrivacyChange, expectedAccountID: Int64, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest { selectiveWrites += 1; return Request() }
        func applyGlobal(_ change: TelegramGlobalPrivacyChange, expectedAccountID: Int64, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
            XCTAssertEqual(expectedAccountID, accountID); let r = Request(); globalWrites.append((r, change, receive)); return r
        }
    }
    static func snapshot(_ account: Int64 = 1, premium: Bool = true, global: TelegramGlobalPrivacySetting = TelegramGlobalPrivacyTests.initial) -> TelegramPrivacySnapshot {
        .init(accountID: account, settings: TelegramPrivacyControllerTests.snapshot(account: account).settings, global: global,
            capabilities: premium ? TelegramGlobalPrivacyTests.premium : TelegramGlobalPrivacyTests.basic)
    }
    func testGlobalAndSelectiveMutationsShareBarrierAndOnlyReloadAfterAcknowledgement() throws {
        let c = TelegramPrivacyController(), p = Provider(); c.bind(p); c.open(); p.reads[0].1(.success(Self.snapshot()))
        let next = try XCTUnwrap(TelegramGlobalPrivacyTests.initial.replacing(.hideReadTime(true)))
        let change = TelegramGlobalPrivacyChange(expected: TelegramGlobalPrivacyTests.initial, proposed: next)
        XCTAssertTrue(c.applyGlobal(change, contextID: c.contextID))
        guard p.globalWrites.count == 1 else { return XCTFail("Missing global write") }
        XCTAssertEqual(c.snapshot?.global, TelegramGlobalPrivacyTests.initial)
        XCTAssertEqual(c.mutationStatus(for: .presence), .saving)
        XCTAssertFalse(c.apply(.init(expected: TelegramPrivacyTests.setting([.contacts]), audience: .nobody), contextID: c.contextID))
        p.globalWrites[0].2(.success(())); XCTAssertEqual(c.globalMutationStatus, .saved)
        XCTAssertEqual(c.mutationStatus(for: .presence), .idle)
        p.reads[1].1(.success(Self.snapshot(global: next)))
        XCTAssertEqual(c.snapshot?.global, next)
    }
    func testGlobalUncertaintySurvivesCloseAndLateReplyUntilExplicitRefresh() throws {
        let c = TelegramPrivacyController(), p = Provider(); c.bind(p); c.open(); p.reads[0].1(.success(Self.snapshot()))
        let next = try XCTUnwrap(TelegramGlobalPrivacyTests.initial.replacing(.hideReadTime(true)))
        XCTAssertTrue(c.applyGlobal(.init(expected: TelegramGlobalPrivacyTests.initial, proposed: next), contextID: c.contextID))
        guard p.globalWrites.count == 1 else { return XCTFail("Missing global write") }
        c.timeoutMutation(); p.globalWrites[0].2(.success(())); XCTAssertEqual(c.globalMutationStatus, .uncertain)
        c.close(); c.open(); p.reads[1].1(.success(Self.snapshot())); XCTAssertEqual(c.mutationStatus, .uncertain)
        XCTAssertFalse(c.applyGlobal(.init(expected: TelegramGlobalPrivacyTests.initial, proposed: next), contextID: c.contextID))
        c.refresh(); p.reads[2].1(.success(Self.snapshot())); XCTAssertEqual(c.globalMutationStatus, .idle)
        XCTAssertEqual(p.globalWrites.count, 1)
    }
    func testGlobalEditorBasisIsInvalidatedEvenWhenRefreshedValuesAreIdentical() throws {
        let c = TelegramPrivacyController(), p = Provider(); c.bind(p); c.open(); p.reads[0].1(.success(Self.snapshot()))
        let basis = try XCTUnwrap(TelegramGlobalPrivacyEditorBasis(controller: c))
        XCTAssertTrue(basis.isCurrent(in: c)); c.refresh(); p.reads[1].1(.success(Self.snapshot()))
        XCTAssertFalse(basis.isCurrent(in: c))
        let next = try XCTUnwrap(TelegramGlobalPrivacyTests.initial.replacing(.hideReadTime(true)))
        XCTAssertNil(basis.change(to: next, controller: c)); XCTAssertTrue(p.globalWrites.isEmpty)
    }
    func testVoiceMessageMutationRequiresKnownPremiumCapabilities() throws {
        let c = TelegramPrivacyController(), p = Provider(); c.bind(p); c.open(); p.reads[0].1(.success(Self.snapshot(premium: false)))
        let old = try XCTUnwrap(c.snapshot?.settings[.voiceMessages])
        let admitted = c.apply(.init(expected: old, audience: .nobody), contextID: c.contextID)
        XCTAssertFalse(admitted); XCTAssertEqual(p.selectiveWrites, 0)
        guard !admitted else { return }
        c.refresh(); p.reads[1].1(.success(Self.snapshot()))
        XCTAssertTrue(c.apply(.init(expected: old, audience: .nobody), contextID: c.contextID)); XCTAssertEqual(p.selectiveWrites, 1)
    }
    func testRebindingRejectsLateGlobalResultsAndWrongAccountSnapshot() throws {
        let c = TelegramPrivacyController(), p = Provider(), other = Provider(2)
        c.bind(p); c.open(); p.reads[0].1(.success(Self.snapshot()))
        let next = try XCTUnwrap(TelegramGlobalPrivacyTests.initial.replacing(.hideReadTime(true)))
        let oldContext = c.contextID
        XCTAssertTrue(c.applyGlobal(.init(expected: TelegramGlobalPrivacyTests.initial, proposed: next), contextID: oldContext))
        guard p.globalWrites.count == 1 else { return XCTFail("Missing global write") }
        c.bind(other); c.open(); XCTAssertTrue(p.globalWrites[0].0.cancelled)
        p.globalWrites[0].2(.success(())); XCTAssertNil(c.snapshot)
        other.reads[0].1(.success(Self.snapshot())); XCTAssertEqual(c.status, .failed)
        XCTAssertFalse(c.applyGlobal(.init(expected: TelegramGlobalPrivacyTests.initial, proposed: next), contextID: oldContext))
    }
}

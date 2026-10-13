import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramTwoStepControllerTests: XCTestCase {
    func testSyntheticWorkspaceRecoveryAndSetupNeverOpenAnAccount() throws {
        let model = TelegramModel.syntheticPreview(), c = model.accountTwoStep; c.open()
        XCTAssertEqual(c.snapshot?.accountID,-1); XCTAssertEqual(c.snapshot?.enabled,true)
        let recovery = try XCTUnwrap(c.proposal(.requestRecovery)); XCTAssertTrue(c.perform(recovery))
        let recover = try XCTUnwrap(c.proposal(.recover)); XCTAssertTrue(c.perform(recover,input: .init(code: "123456")))
        XCTAssertEqual(c.snapshot?.enabled,false)
        let setup = try XCTUnwrap(c.proposal(.setPassword)); XCTAssertTrue(c.perform(setup,input: .init(password: "Synthetic-New-Pass",confirmation: "Synthetic-New-Pass",hint: "A synthetic hint")))
        XCTAssertEqual(c.snapshot?.enabled,true); XCTAssertFalse(c.isUnlocked); XCTAssertTrue(model.isSyntheticPreview)
    }
    static func state(account: Int64 = 1, enabled: Bool = true, pending: String? = nil, secure: Bool = false, reset: Int32? = nil) -> TelegramTwoStepSnapshot {
        .init(accountID: account, enabled: enabled, hint: "Synthetic hint", hasRecoveryEmail: enabled, pendingEmail: pending, hasSecureValues: secure, resetAt: reset, basisTag: "synthetic-basis")
    }
    private final class Request: TelegramPrivacyRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramTwoStepProvider {
        let accountID: Int64
        init(_ id: Int64 = 1) { accountID = id }
        var reads: [(Request, @MainActor (Result<TelegramTwoStepSnapshot, TelegramTwoStepError>) -> Void)] = []
        var actions: [(Request, TelegramTwoStepProposal, TelegramTwoStepInput, @MainActor (Result<TelegramTwoStepOutcome, TelegramTwoStepError>) -> Void)] = []
        func load(receive: @escaping @MainActor (Result<TelegramTwoStepSnapshot, TelegramTwoStepError>) -> Void) -> any TelegramPrivacyRequest { let r = Request(); reads.append((r,receive)); return r }
        func perform(_ proposal: TelegramTwoStepProposal, input: TelegramTwoStepInput, receive: @escaping @MainActor (Result<TelegramTwoStepOutcome, TelegramTwoStepError>) -> Void) -> any TelegramPrivacyRequest { let r = Request(); actions.append((r,proposal,input,receive)); return r }
    }
    private func loaded(_ state: TelegramTwoStepSnapshot = state()) throws -> (TelegramTwoStepController, Provider) {
        let c = TelegramTwoStepController(), p = Provider(state.accountID); c.bind(p); c.open()
        let read = try XCTUnwrap(p.reads.first); read.1(.success(state)); return (c,p)
    }
    func testExpiringProofRevokesCredentialsAndAnOldConfirmationCannotBorrowNewProof() throws {
        let (c,p) = try loaded()
        XCTAssertTrue(c.perform(try XCTUnwrap(c.proposal(.unlock)),input: .init(password: "Synthetic-Pass")))
        p.actions.last?.3(.success(.unlocked("synthetic@example.invalid")))
        let old = try XCTUnwrap(c.proposal(.disable)); c.expireProof()
        XCTAssertFalse(c.isUnlocked); XCTAssertNil(c.recoveryEmail); XCTAssertNil(c.proposal(.disable))
        XCTAssertTrue(c.perform(try XCTUnwrap(c.proposal(.unlock)),input: .init(password: "Synthetic-Pass")))
        p.actions.last?.3(.success(.unlocked("synthetic@example.invalid")))
        XCTAssertFalse(c.perform(old)); XCTAssertNotNil(c.proposal(.disable))
    }
    func testSyntheticPasswordProofUsesTheSameExactBytesAsTheNativeEngine() throws {
        let c = TelegramModel.syntheticPreview().accountTwoStep; c.open()
        XCTAssertTrue(c.perform(try XCTUnwrap(c.proposal(.requestRecovery))))
        XCTAssertTrue(c.perform(try XCTUnwrap(c.proposal(.recover)),input: .init(code: "123456")))
        XCTAssertTrue(c.perform(try XCTUnwrap(c.proposal(.setPassword)),input: .init(password: "é",confirmation: "é")))
        XCTAssertTrue(c.perform(try XCTUnwrap(c.proposal(.unlock)),input: .init(password: "e\u{301}")))
        XCTAssertFalse(c.isUnlocked)
    }
    func testRejectedWriteConsumesItsProofAndOldConsentCannotBorrowASecondUnlock() throws {
        let (c,p) = try loaded()
        XCTAssertTrue(c.perform(try XCTUnwrap(c.proposal(.unlock)),input: .init(password: "Synthetic-Pass")))
        p.actions.last?.3(.success(.unlocked("synthetic@example.invalid")))
        let old = try XCTUnwrap(c.proposal(.disable))
        XCTAssertTrue(c.perform(old)); p.actions.last?.3(.failure(.invalidPassword))
        XCTAssertTrue(c.perform(try XCTUnwrap(c.proposal(.unlock)),input: .init(password: "Synthetic-Pass")))
        p.actions.last?.3(.success(.unlocked("synthetic@example.invalid")))
        XCTAssertFalse(c.perform(old)); XCTAssertNotNil(c.proposal(.disable))
    }
    func testLockedSettingsRequirePasswordProofAndClearProofOnRefresh() throws {
        let (c,p) = try loaded()
        XCTAssertNil(c.proposal(.changePassword)); XCTAssertNil(c.proposal(.disable))
        let unlock = try XCTUnwrap(c.proposal(.unlock))
        XCTAssertTrue(c.perform(unlock, input: .init(password: "Synthetic-Passphrase")))
        p.actions.last?.3(.success(.unlocked("synthetic@example.invalid")))
        XCTAssertTrue(c.isUnlocked); XCTAssertEqual(c.recoveryEmail, "synthetic@example.invalid")
        let disable = try XCTUnwrap(c.proposal(.disable)); XCTAssertTrue(c.perform(disable))
        XCTAssertEqual(p.actions.last?.2.currentPassword, "Synthetic-Passphrase")
        p.actions.last?.3(.success(.done)); XCTAssertFalse(c.isUnlocked); XCTAssertNil(c.recoveryEmail)
        XCTAssertNil(c.snapshot); p.reads.last?.1(.success(Self.state(enabled: false)))
        XCTAssertNotNil(c.proposal(.setPassword)); XCTAssertFalse(c.perform(disable))
    }
    func testCloseDuringWriteRetainsUncertaintyWithoutRetainingCredentialProof() throws {
        let (c,p) = try loaded(Self.state(enabled: false))
        let proposal = try XCTUnwrap(c.proposal(.setPassword))
        XCTAssertTrue(c.perform(proposal, input: .init(password: "Synthetic-Pass",confirmation: "Synthetic-Pass",hint: "A synthetic hint")))
        let action = try XCTUnwrap(p.actions.first)
        c.close(); c.open(); action.3(.success(.done)); p.reads.last?.1(.success(Self.state(enabled: false)))
        XCTAssertTrue(action.0.cancelled); XCTAssertTrue(c.isUncertain); XCTAssertFalse(c.isUnlocked)
        XCTAssertNil(c.proposal(.setPassword)); c.refresh(); p.reads.last?.1(.success(Self.state(enabled: false)))
        XCTAssertFalse(c.isUncertain); XCTAssertNotNil(c.proposal(.setPassword)); XCTAssertEqual(p.actions.count, 1)
    }
    func testRefreshInvalidatesEvenIdenticalProposalAndRebindingRejectsOldCallbacks() throws {
        let (c,p) = try loaded(Self.state(enabled: false)), old = try XCTUnwrap(c.proposal(.setPassword))
        c.refresh(); p.reads.last?.1(.success(Self.state(enabled: false)))
        XCTAssertFalse(c.perform(old, input: .init(password: "P",confirmation: "P")))
        let other = Provider(2); c.bind(other); c.open(); p.reads.first?.1(.success(Self.state()))
        XCTAssertNil(c.snapshot); other.reads.first?.1(.success(Self.state()))
        XCTAssertEqual(c.status, .failed); XCTAssertNil(c.proposal(.unlock))
    }
    func testRecoveryAndEmailActionsRequireTheirOwnServerState() throws {
        let (c,p) = try loaded()
        XCTAssertNil(c.proposal(.confirmEmail)); XCTAssertNil(c.proposal(.recover))
        let request = try XCTUnwrap(c.proposal(.requestRecovery)); XCTAssertTrue(c.perform(request))
        p.actions.last?.3(.success(.recoverySent("s***@example.invalid")))
        XCTAssertEqual(c.recoveryPattern, "s***@example.invalid"); XCTAssertNotNil(c.proposal(.recover))
        XCTAssertNil(c.proposal(.changeEmail)); XCTAssertFalse(c.isUnlocked)
        c.refresh(); p.reads.last?.1(.success(Self.state(pending: "s***@example.invalid")))
        XCTAssertNil(c.proposal(.recover)); XCTAssertNotNil(c.proposal(.confirmEmail)); XCTAssertNotNil(c.proposal(.cancelEmail))
    }
    func testOnlyWriteTimeoutRequiresReconciliationAndLateUnlockCannotRestoreProof() throws {
        let (c,p) = try loaded(), proposal = try XCTUnwrap(c.proposal(.unlock))
        XCTAssertTrue(c.perform(proposal,input: .init(password: "Synthetic-Pass")))
        c.timeoutAction(); p.actions.last?.3(.success(.unlocked("synthetic@example.invalid")))
        XCTAssertFalse(c.isUnlocked); XCTAssertFalse(c.isUncertain); XCTAssertFalse(c.isWorking)
        let retry = try XCTUnwrap(c.proposal(.unlock)); XCTAssertTrue(c.perform(retry,input: .init(password: "Synthetic-Pass")))
        p.actions.last?.3(.success(.unlocked("synthetic@example.invalid")))
        let disable = try XCTUnwrap(c.proposal(.disable)); XCTAssertTrue(c.perform(disable)); c.timeoutAction()
        p.actions.last?.3(.success(.done)); XCTAssertTrue(c.isUncertain); XCTAssertFalse(c.isUnlocked)
    }
}

final class TelegramTwoStepInputTests: XCTestCase {
    func testPasswordAndEmailValidationPreservesPasswordWhitespaceAndRefusesMismatchOrRevealingHint() {
        XCTAssertTrue(TelegramTwoStepInput(password: " Synthetic-Pass ",confirmation: " Synthetic-Pass ",hint: "Hint").isValid(for: .setPassword))
        for input in [TelegramTwoStepInput(password: "X",confirmation: "Y"), .init(password: "X",confirmation: "X",hint: "x"), .init(password: "X",confirmation: "X",email: "bad"), .init(password: String(repeating: "x",count: 1025),confirmation: "x")] {
            XCTAssertFalse(input.isValid(for: .setPassword))
        }
        XCTAssertTrue(TelegramTwoStepInput(email: "synthetic@example.invalid").isValid(for: .changeEmail))
        XCTAssertFalse(TelegramTwoStepInput(email: "synthetic @example.invalid").isValid(for: .changeEmail))
        XCTAssertTrue(TelegramTwoStepInput(code: "123456").isValid(for: .confirmEmail))
        XCTAssertFalse(TelegramTwoStepInput(code: "１２３４５６").isValid(for: .confirmEmail))
    }
    func testSecretDescriptionsNeverPrintInputs() {
        let input = TelegramTwoStepInput(password: "Synthetic-Pass",confirmation: "Synthetic-Pass",hint: "Synthetic Hint",email: "synthetic@example.invalid",code: "123456")
        for rendered in [String(describing: input), String(reflecting: input)] {
            for secret in ["Synthetic-Pass", "Synthetic Hint", "synthetic@example.invalid", "123456"] {
                XCTAssertFalse(rendered.contains(secret))
            }
        }
    }
}

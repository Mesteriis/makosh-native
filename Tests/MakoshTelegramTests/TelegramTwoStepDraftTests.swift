import XCTest
@testable import MakoshTelegram

final class TelegramTwoStepDraftTests: XCTestCase {
    func testSetupKeepsExactPasswordAndRequiresConsentToOmitRecoveryEmail() throws {
        var draft = TelegramTwoStepPasswordDraft(kind: .setPassword)
        draft.password = " Synthetic-Pass "
        XCTAssertTrue(draft.advance()); XCTAssertEqual(draft.stage,.confirmation)
        draft.confirmation = " Synthetic-Pass "; XCTAssertTrue(draft.advance())
        draft.hint = "Synthetic hint"; XCTAssertTrue(draft.advance()); XCTAssertEqual(draft.stage,.email)
        XCTAssertFalse(draft.advance()); XCTAssertNil(draft.input)
        XCTAssertTrue(draft.advance(skipEmail: true)); XCTAssertEqual(draft.stage,.review)
        let input = try XCTUnwrap(draft.input); XCTAssertEqual(Array(input.password.utf8),Array(" Synthetic-Pass ".utf8))
        XCTAssertEqual(input.email,"")
        draft.clear(); XCTAssertNil(draft.input); XCTAssertTrue(draft.password.isEmpty); XCTAssertTrue(draft.confirmation.isEmpty); XCTAssertTrue(draft.hint.isEmpty)
        XCTAssertEqual(draft.stage,.password)
    }
    func testPasswordChangePreservesRecoveryEmailByOmittingEmailMutation() throws {
        var draft = TelegramTwoStepPasswordDraft(kind: .changePassword)
        draft.password = "Synthetic-Pass"; XCTAssertTrue(draft.advance())
        draft.confirmation = "Wrong"; XCTAssertFalse(draft.advance()); XCTAssertEqual(draft.stage,.confirmation)
        draft.confirmation = "Synthetic-Pass"; XCTAssertTrue(draft.advance())
        draft.hint = "synthetic-pass"; XCTAssertFalse(draft.advance())
        draft.hint = "Synthetic hint"; XCTAssertTrue(draft.advance()); XCTAssertEqual(draft.stage,.review)
        XCTAssertEqual(try XCTUnwrap(draft.input).email,"")
        draft.back(); XCTAssertEqual(draft.stage,.hint); XCTAssertNil(draft.input)
    }
    func testUnicodeCanonicalEquivalenceCannotChangeConfirmedPasswordBytes() {
        XCTAssertFalse(TelegramTwoStepInput(password: "é",confirmation: "e\u{301}").isValid(for: .setPassword))
        XCTAssertNil(telegramTwoStepPasswordOutcome(.password(password: "e\u{301}",pendingEmail: nil),kind: .setPassword,input: .init(password: "é",confirmation: "é")))
    }
}

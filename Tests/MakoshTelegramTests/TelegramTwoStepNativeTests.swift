import XCTest
import TelegramApi
import SwiftSignalKit
import TelegramCore
@testable import MakoshTelegram

final class TelegramTwoStepNativeTests: XCTestCase {
    func testNativePasswordResultCannotSubstituteAnotherSecretOrOperation() {
        let input = TelegramTwoStepInput(password: "Synthetic-Pass",confirmation: "Synthetic-Pass")
        XCTAssertEqual(telegramTwoStepPasswordOutcome(.password(password: "Synthetic-Pass",pendingEmail: nil),kind: .setPassword,input: input), .done)
        XCTAssertNil(telegramTwoStepPasswordOutcome(.password(password: "Other-Synthetic-Pass",pendingEmail: nil),kind: .setPassword,input: input))
        XCTAssertNil(telegramTwoStepPasswordOutcome(.none,kind: .setPassword,input: input))
        XCTAssertEqual(telegramTwoStepPasswordOutcome(.none,kind: .disable,input: .init()),.done)
        XCTAssertEqual(telegramTwoStepPasswordOutcome(.password(password: "Synthetic-Pass",pendingEmail: .init(pattern: "s***@example.invalid",codeLength: 6)),kind: .setPassword,input: input),.pendingEmail("s***@example.invalid",6))
    }
    func testRecoveryRPCDoesNotInstallNewCredentialsAndRequiresTheSelectedAccountAcknowledgement() throws {
        let rpc = try XCTUnwrap(telegramTwoStepRecoveryRPC(input: .init(code: "123456")))
        XCTAssertEqual(rpc.0.name,"auth.recoverPassword")
        let reader = BufferReader(rpc.1); _ = reader.readInt32(); XCTAssertEqual(reader.readInt32(),0)
        XCTAssertNil(telegramTwoStepRecoveryRPC(input: .init(code: "")))
        let value: Api.auth.Authorization = .authorization(flags: 0,otherwiseReloginDays: nil,tmpSessions: nil,futureAuthToken: nil,user: TelegramBlockedUsersNativeTests.user(7))
        XCTAssertEqual(telegramTwoStepRecoveryOutcome(value,selfID: 7),.done)
        XCTAssertNil(telegramTwoStepRecoveryOutcome(value,selfID: 8))
    }
    func testResetWaitingAndRejectionAreNeverReportedAsImmediateRemoval() {
        XCTAssertEqual(telegramTwoStepResetOutcome(.resetPasswordRequestedWait(untilDate: 2000)),.success(.resetWaiting(2000)))
        XCTAssertEqual(telegramTwoStepResetOutcome(.resetPasswordOk),.success(.done))
        XCTAssertEqual(telegramTwoStepResetOutcome(.resetPasswordFailedWait(retryDate: 2000)),.failure(.flood))
        XCTAssertEqual(telegramTwoStepResetOutcome(.resetPasswordRequestedWait(untilDate: -1)),.failure(.uncertain))
    }
    func testSafeErrorMappingSeparatesRejectedInputFromUnknownWriteOutcome() {
        XCTAssertEqual(telegramTwoStepRPCError(code: 400,description: "PASSWORD_HASH_INVALID",writing: true),.invalidPassword)
        XCTAssertEqual(telegramTwoStepRPCError(code: 400,description: "CODE_INVALID",writing: true),.invalidCode)
        XCTAssertEqual(telegramTwoStepRPCError(code: 420,description: "FLOOD_WAIT_10",writing: true),.flood)
        XCTAssertEqual(telegramTwoStepRPCError(code: 500,description: "PRIVATE_UNKNOWN_DETAIL",writing: true),.uncertain)
        XCTAssertEqual(telegramTwoStepRPCError(code: 500,description: "PRIVATE_UNKNOWN_DETAIL",writing: false),.unavailable)
    }
    func testServerFailuresAndMalformedFloodDescriptionsCannotMasqueradeAsRejectedInput() {
        for description in ["CODE_INVALID","PASSWORD_HASH_INVALID","EMAIL_INVALID","FLOOD_WAIT_10"] {
            XCTAssertEqual(telegramTwoStepRPCError(code: 500,description: description,writing: true),.uncertain)
        }
        for description in ["FLOOD_WAIT","FLOOD_WAIT_","FLOOD_WAIT_-1","FLOOD_WAIT_PRIVATE_DETAIL"] {
            XCTAssertEqual(telegramTwoStepRPCError(code: 420,description: description,writing: true),.uncertain)
        }
    }
    private func response(salt: UInt8 = 1) -> Api.account.Password {
        let algo: Api.PasswordKdfAlgo = .passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow(salt1: Buffer(data: Data([salt])), salt2: Buffer(data: Data([2])), g: 2, p: Buffer(data: Data(repeating: 1,count: 256)))
        return .password(flags: 7, currentAlgo: algo, srpB: Buffer(data: Data([3])), srpId: 7, hint: "Synthetic hint", emailUnconfirmedPattern: nil, newAlgo: algo, newSecureAlgo: .securePasswordKdfAlgoUnknown, secureRandom: Buffer(data: Data([4])), pendingResetDate: nil, loginEmailPattern: nil)
    }
    func testNativeConfigurationKeepsRecoverySecureValuesAndAnOpaquePasswordBasis() throws {
        let value = try XCTUnwrap(telegramTwoStepSnapshot(response(),accountID: 1))
        XCTAssertTrue(value.enabled); XCTAssertTrue(value.hasRecoveryEmail); XCTAssertTrue(value.hasSecureValues)
        XCTAssertEqual(value.hint,"Synthetic hint"); XCTAssertTrue(value.isValid)
        XCTAssertNotEqual(value.basisTag,telegramTwoStepSnapshot(response(salt: 9),accountID: 1)?.basisTag)
        XCTAssertNil(telegramTwoStepSnapshot(response(),accountID: 0))
    }
    func testTypedEmailAndRecoveryCodeRPCsCannotAliasEachOther() throws {
        for (kind,name): (TelegramTwoStepKind,String) in [(.confirmEmail,"account.confirmPasswordEmail"),(.resendEmail,"account.resendPasswordEmail"),(.cancelEmail,"account.cancelPasswordEmail"),(.declineReset,"account.declinePasswordReset")] {
            let rpc = try XCTUnwrap(telegramTwoStepBoolRPC(kind,input: .init(code: "123456")))
            XCTAssertEqual(rpc.0.name,name)
        }
        XCTAssertNil(telegramTwoStepBoolRPC(.disable,input: .init()))
    }
    func testEmptyAndFalseAcknowledgementsNeverBecomeSuccess() {
        for mode in 0...3 {
            let signal: Signal<Api.Bool,TelegramTwoStepError> = mode == 0 ? .single(.boolTrue) : mode == 1 ? .single(.boolFalse) : mode == 2 ? .complete() : .fail(.uncertain)
            var success = 0, errors: [TelegramTwoStepError] = []
            let d = telegramTwoStepBoolAcknowledgement(signal).start(next: { _ in success += 1 },error: { errors.append($0) }); defer { d.dispose() }
            XCTAssertEqual(success,mode == 0 ? 1 : 0); XCTAssertEqual(errors,mode == 0 ? [] : [.uncertain])
        }
    }
    @MainActor func testFreshPasswordBasisAndAccountMustMatchBeforeAnyWrite() {
        let old = TelegramTwoStepControllerTests.state(), proposal = TelegramTwoStepProposal(kind: .disable,contextID: UUID(),expected: old)
        for mode in 0...2 {
            var sends = 0, values = 0, errors: [TelegramTwoStepError] = []
            let d = telegramPerformTwoStep(proposal: proposal,accountID: mode == 1 ? 2 : 1,
                load: { .single(mode == 2 ? TelegramTwoStepControllerTests.state(enabled: false) : old) },
                perform: { sends += 1; return .single(.done) }).start(next: { _ in values += 1 },error: { errors.append($0) }); defer { d.dispose() }
            XCTAssertEqual(sends,mode == 0 ? 1 : 0); XCTAssertEqual(values,mode == 0 ? 1 : 0)
            XCTAssertEqual(errors,mode == 0 ? [] : [.changed])
        }
    }
}

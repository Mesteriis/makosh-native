import XCTest
import TelegramCore
import TelegramApi
import SwiftSignalKit
import MtProtoKit

final class TelegramTwoStepAcknowledgementTests: XCTestCase {
    func testNativePasswordErrorNeedsExpectedNumericCodeAndStrictPendingDescription() {
        for code: Int32 in [400,500] {
            let value = makoshTwoStepPasswordError(MTRpcError(errorCode: code,errorDescription: "EMAIL_INVALID"))
            if case .invalidEmail = value { XCTAssertEqual(code,400) }
            else { XCTAssertEqual(code,500) }
            XCTAssertEqual(makoshTwoStepEmailPending(MTRpcError(errorCode: code,errorDescription: "EMAIL_UNCONFIRMED_6")),code == 400)
        }
        for text in ["EMAIL_UNCONFIRMED_","EMAIL_UNCONFIRMED_-1","EMAIL_UNCONFIRMED_0","EMAIL_UNCONFIRMED_17","EMAIL_UNCONFIRMED_PRIVATE"] {
            XCTAssertFalse(makoshTwoStepEmailPending(MTRpcError(errorCode: 400,errorDescription: text)))
        }
        XCTAssertTrue(makoshTwoStepEmailPending(MTRpcError(errorCode: 400,errorDescription: "EMAIL_UNCONFIRMED")))
    }
    func testMissingOrUnexpectedProtectedSecretAndUnsupportedAlgorithmRefusePasswordMutation() {
        XCTAssertTrue(makoshTwoStepSecureValuesConsistent(false,false))
        XCTAssertTrue(makoshTwoStepSecureValuesConsistent(true,true))
        XCTAssertFalse(makoshTwoStepSecureValuesConsistent(true,false))
        XCTAssertFalse(makoshTwoStepSecureValuesConsistent(false,true))
        XCTAssertTrue(makoshTwoStepNextSecureAlgoSupported(.securePasswordKdfAlgoUnknown))
        XCTAssertTrue(makoshTwoStepNextSecureAlgoSupported(.securePasswordKdfAlgoPBKDF2HMACSHA512iter100000(salt: Buffer(data: Data([1])))))
        XCTAssertFalse(makoshTwoStepNextSecureAlgoSupported(.securePasswordKdfAlgoSHA512(salt: Buffer(data: Data([1])))))
    }
    func testNativePasswordAcknowledgementRefusesFalseBeforeReportingSuccess() {
        for value: Api.Bool in [.boolTrue,.boolFalse] {
            var accepted = 0, rejected = 0
            let d = makoshTwoStepPasswordAcknowledgement(value, result: .none).start(next: { _ in accepted += 1 }, error: { _ in rejected += 1 })
            defer { d.dispose() }
            if case .boolTrue = value { XCTAssertEqual(accepted, 1); XCTAssertEqual(rejected, 0) }
            else { XCTAssertEqual(accepted, 0); XCTAssertEqual(rejected, 1) }
        }
    }
}

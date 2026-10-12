import XCTest
import TelegramCore
@testable import MakoshTelegram

final class TelegramAuthorizationChallengeTests: XCTestCase {
    private var phoneTypes: [SentAuthorizationCodeType] {
        [.otherSession(length: 5), .sms(length: 5), .call(length: 5),
         .word(startsWith: "synthetic-private-marker"), .phrase(startsWith: nil)]
    }
    private var emailType: SentAuthorizationCodeType {
        .email(emailPattern: "synthetic-private-marker@example.invalid", length: 6,
               resetAvailablePeriod: nil, resetPendingDate: nil, appleSignInAllowed: false, setup: false)
    }
    private var unsupportedTypes: [SentAuthorizationCodeType] {
        [.email(emailPattern: "synthetic-private-marker@example.invalid", length: 6,
                resetAvailablePeriod: 10, resetPendingDate: 20, appleSignInAllowed: true, setup: true),
         .emailSetupRequired(appleSignInAllowed: false),
         .firebase(pushTimeout: 10, length: 6),
         .fragment(url: "https://example.invalid/synthetic-private-marker", length: 6),
         .flashCall(pattern: "synthetic-private-marker"),
         .missedCall(numberPrefix: "synthetic-private-marker", length: 4)]
    }

    func testClassificationAndPhaseCoverEveryServerChallenge() {
        for type in phoneTypes {
            let challenge = TelegramAuthorizationChallenge(type: type)
            XCTAssertEqual(challenge, .phoneCode)
            XCTAssertEqual(challenge.phase, .code)
            XCTAssertFalse(challenge.explanation.isEmpty)
            XCTAssertFalse(challenge.explanation.contains("synthetic-private-marker"))
        }
        let email = TelegramAuthorizationChallenge(type: emailType)
        XCTAssertEqual(email, .emailCode)
        XCTAssertEqual(email.phase, .code)
        XCTAssertFalse(email.explanation.contains("synthetic-private-marker"))
        for type in unsupportedTypes {
            let challenge = TelegramAuthorizationChallenge(type: type)
            guard case .unsupported(let message) = challenge else { return XCTFail("Unsupported flow was offered as code entry") }
            XCTAssertEqual(challenge.phase, .unsupported(message))
            XCTAssertEqual(challenge.explanation, message)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("synthetic-private-marker"))
            XCTAssertFalse(message.contains("https://"))
        }
    }

    func testPayloadUsesEmailVerificationOnlyForEmailAndRefusesUnsupportedFlows() {
        let value = "synthetic code or phrase"
        for type in phoneTypes {
            XCTAssertEqual(TelegramAuthorizationChallenge(type: type).authorizationCode(value), .phoneCode(value))
        }
        XCTAssertEqual(TelegramAuthorizationChallenge(type: emailType).authorizationCode(value), .emailVerification(.emailCode(value)))
        for type in unsupportedTypes {
            XCTAssertNil(TelegramAuthorizationChallenge(type: type).authorizationCode(value))
        }
    }
}

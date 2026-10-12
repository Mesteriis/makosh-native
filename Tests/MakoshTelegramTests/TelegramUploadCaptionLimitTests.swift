import XCTest
import Foundation
import TelegramCore
@testable import MakoshTelegram

final class TelegramUploadCaptionLimitTests: XCTestCase {
    private func configuration(_ values: [String: JSON] = [:]) throws -> AppConfiguration {
        let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSON.dictionary(values)))
        return try JSONDecoder().decode(AppConfiguration.self,
            from: JSONSerialization.data(withJSONObject: ["data": data, "storedHash": 0]))
    }

    // Catches applying the free tier's boundary to a premium preparation.
    func testPremiumBoundaryCountsUTF16AndRetainsUnsupportedEntityVeto() throws {
        let boundary = try TelegramFormattedText(text: String(repeating: "😀", count: 1024))
        XCTAssertTrue(TelegramUploadCaptionRules.reference.canSend(boundary, maximumUTF16Count: 2048))
        XCTAssertTrue(telegramFormattedCaptionCanSend(boundary, maximumUTF16Count: 2048))
        let excessive = try TelegramFormattedText(text: boundary.text + "x")
        XCTAssertFalse(TelegramUploadCaptionRules.reference.canSend(excessive, maximumUTF16Count: 2048))
        XCTAssertFalse(telegramFormattedCaptionCanSend(excessive, maximumUTF16Count: 2048))
        XCTAssertFalse(telegramFormattedCaptionCanSend(boundary))
        let unsupported = try TelegramFormattedText(text: "😀", entities: [
            .init(offset: 0, length: 2, kind: .customEmoji(stickerPack: nil, fileID: 10))])
        XCTAssertFalse(TelegramUploadCaptionRules.reference.canSend(unsupported, maximumUTF16Count: 2048))
        XCTAssertFalse(telegramFormattedCaptionCanSend(unsupported, maximumUTF16Count: 2048))
    }

    // Catches selecting the other account tier or ignoring a server-configured boundary.
    func testAccountTierSelectsTheCorrespondingConfigurationOrDefault() throws {
        let empty = try configuration()
        XCTAssertEqual(TelegramUploadCaptionLimit.resolve(appConfiguration: empty, isPremium: false), 1024)
        XCTAssertEqual(TelegramUploadCaptionLimit.resolve(appConfiguration: empty, isPremium: true), 2048)
        let configured = try configuration(["caption_length_limit_default": .number(700),
            "caption_length_limit_premium": .number(3000)])
        XCTAssertEqual(TelegramUploadCaptionLimit.resolve(appConfiguration: configured, isPremium: false), 700)
        XCTAssertEqual(TelegramUploadCaptionLimit.resolve(appConfiguration: configured, isPremium: true), 3000)
        let boundary = try TelegramFormattedText(text: String(repeating: "a", count: 3000))
        XCTAssertTrue(TelegramUploadCaptionRules.reference.canSend(boundary,
            maximumUTF16Count: TelegramUploadCaptionLimit.resolve(appConfiguration: configured, isPremium: true)))
        XCTAssertFalse(TelegramUploadCaptionRules.reference.canSend(boundary,
            maximumUTF16Count: TelegramUploadCaptionLimit.resolve(appConfiguration: configured, isPremium: false)))
    }

    // Catches a malformed configuration trapping integer conversion or widening admission.
    func testInvalidConfiguredLimitsUseTierDefaults() throws {
        for invalid: JSON in [.number(0), .number(-1), .number(2048.5),
                              .number(Double(Int32.max) + 1), .string("3000"), .bool(true), .null] {
            let configured = try configuration(["caption_length_limit_default": invalid,
                "caption_length_limit_premium": invalid])
            XCTAssertEqual(TelegramUploadCaptionLimit.resolve(appConfiguration: configured, isPremium: false), 1024)
            XCTAssertEqual(TelegramUploadCaptionLimit.resolve(appConfiguration: configured, isPremium: true), 2048)
        }
        for invalid in [0, -1, Int(Int32.max) + 1] {
            let value = try TelegramFormattedText(text: "")
            XCTAssertFalse(TelegramUploadCaptionRules.reference.canSend(value, maximumUTF16Count: invalid))
            XCTAssertFalse(telegramFormattedCaptionCanSend(value, maximumUTF16Count: invalid))
        }
    }

    // Catches counting discarded edge padding while still preserving raw U+FFFC preflight behavior.
    func testReferencePreflightUsesConfiguredBoundaryWithoutChangingRawInput() throws {
        let raw = try TelegramFormattedText(text: "  😀😀\n")
        XCTAssertTrue(TelegramUploadCaptionRules.reference.canSend(raw, maximumUTF16Count: 4))
        XCTAssertFalse(TelegramUploadCaptionRules.legacy.canSend(raw, maximumUTF16Count: 4))
        XCTAssertEqual(raw.text, "  😀😀\n")
        let placeholders = try TelegramFormattedText(text: "\u{fffc}\u{fffc}x")
        XCTAssertFalse(TelegramUploadCaptionRules.reference.canSend(placeholders, maximumUTF16Count: 1))
    }
}

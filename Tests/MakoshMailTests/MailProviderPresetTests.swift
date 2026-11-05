import XCTest
@testable import MakoshMail

final class MailProviderPresetTests: XCTestCase {
    func testPublicProvidersUseVerifiedTLSEndpoints() throws {
        let expected: [MailProviderPreset: (String, Int, MailConnectionSecurity, String, Int, MailConnectionSecurity)] = [
            .iCloud: ("imap.mail.me.com", 993, .tls, "smtp.mail.me.com", 587, .startTLS),
            .gmail: ("imap.gmail.com", 993, .tls, "smtp.gmail.com", 465, .tls),
            .yandex: ("imap.yandex.ru", 993, .tls, "smtp.yandex.ru", 465, .tls),
            .mailRu: ("imap.mail.ru", 993, .tls, "smtp.mail.ru", 465, .tls),
            .proton: ("127.0.0.1", 1143, .startTLS, "127.0.0.1", 1025, .startTLS),
        ]
        for (preset, value) in expected {
            let servers = try XCTUnwrap(preset.servers, "\(preset)")
            XCTAssertEqual(servers.imapHost, value.0)
            XCTAssertEqual(servers.imapPort, value.1)
            XCTAssertEqual(servers.imapSecurity, value.2)
            XCTAssertEqual(servers.smtpHost, value.3)
            XCTAssertEqual(servers.smtpPort, value.4)
            XCTAssertEqual(servers.smtpSecurity, value.5)
            XCTAssertFalse(preset.title.isEmpty)
            XCTAssertFalse(preset.hint.isEmpty)
        }
    }

    func testOtherLeavesManualEntry() {
        XCTAssertNil(MailProviderPreset.other.servers)
        XCTAssertEqual(MailProviderPreset.allCases.last, .other)
        XCTAssertEqual(MailProviderPreset.allCases.count, 6)
    }

    func testExistingAccountMatchesItsPreset() {
        let gmail = MailAccount(
            id: "a", displayName: "", email: "x@gmail.com", imapHost: "IMAP.gmail.com", imapPort: 993, imapSecurity: .tls,
            imapUsername: "x", smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .tls, smtpUsername: "x")
        XCTAssertEqual(MailProviderPreset(matching: gmail), .gmail)
        var custom = gmail
        custom.smtpPort = 587
        XCTAssertEqual(MailProviderPreset(matching: custom), .other)
    }
}

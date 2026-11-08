import Foundation
import MakoshCore
import XCTest
@testable import MakoshMail

@MainActor final class MailComposeAttachmentsTests: XCTestCase {
    func testComposeWithAttachmentsAndAddress() async throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PostgreSQL required") }
        let config = PersonWorkspaceConfiguration(
            connectionString: dsn, schema: "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let repository = MailRepository(configuration: config, keyProvider: { _, _ in Data(repeating: 0x73, count: 32) })
        let account = MailAccount(
            displayName: "A", email: "a@example.invalid", imapHost: "imap.example.invalid", imapUsername: "a",
            smtpHost: "smtp.example.invalid",
            smtpUsername: "a")
        try await repository.saveAccount(account)
        try await repository.saveFolders(
            [MailFolder(accountID: account.id, path: "INBOX", kind: .inbox, uidValidity: 1)], accountID: account.id)
        let model = MailWorkspaceModel(synthetic: true)
        await model.load(configuration: config)
        let file = URL(fileURLWithPath: "/tmp/форма.pdf")
        model.compose(to: "maria@example.invalid", attachments: [file])
        XCTAssertEqual(model.composer?.accountID, account.id)
        XCTAssertEqual(model.composer?.to, "maria@example.invalid")
        XCTAssertEqual(model.composerAttachments, [file])
        XCTAssertEqual(model.takeComposerAttachments(), [file], "the sheet takes the files once")
        XCTAssertEqual(model.composerAttachments, [])
        model.compose()
        XCTAssertEqual(model.composer?.to, "", "a plain new letter has no address and no files")
        XCTAssertEqual(model.composerAttachments, [])
    }
}

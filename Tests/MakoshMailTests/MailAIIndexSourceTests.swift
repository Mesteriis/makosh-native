import MakoshCore
import XCTest
@testable import MakoshMail

final class MailAIIndexSourceTests: XCTestCase {
    private func repository() throws -> MailRepository {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
            throw XCTSkip("Real PostgreSQL test configuration required")
        }
        let schema = "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        addTeardownBlock {
            let connection = try PostgresConnection(connectionString: dsn)
            _ = try connection.query("DROP SCHEMA IF EXISTS \"\(schema)\" CASCADE", [])
            connection.close()
        }
        return MailRepository(configuration: .init(connectionString: dsn, schema: schema), keyProvider: { _, _ in Data(repeating: 9, count: 32) })
    }
    private func account(_ email: String) -> MailAccount {
        .init(
            displayName: "QA", email: email, imapHost: "imap.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid",
            smtpUsername: "qa")
    }
    private func letter(_ account: MailAccount, uid: UInt32, from: String, text: String?, html: String? = nil) -> MailLetter {
        MailLetter(
            key: MailMessageKey(accountID: account.id, folder: "INBOX", uidValidity: 1, uid: uid), subject: "Subject \(uid)",
            senderName: "Sender", sender: from, recipient: account.email, date: Date(timeIntervalSince1970: 1_000 + Double(uid)), text: text,
            html: html)
    }

    func testVersionsAscendingFromCursor() async throws {
        let repository = try repository(), mine = account("me@example.invalid")
        try await repository.saveAccount(mine)
        try await repository.saveLetters([
            letter(mine, uid: 1, from: "Peer@Example.invalid", text: "first"), letter(mine, uid: 2, from: "me@example.invalid", text: "second"),
        ])
        let source = MailAIIndexSource(repository: repository)
        XCTAssertEqual(source.name, "mail")
        let first = try await source.items(after: 0, limit: 1)
        XCTAssertEqual(first.map(\.text), ["first"])
        XCTAssertEqual(first[0].scope, .mailAccount(accountID: mine.id))
        XCTAssertEqual(first[0].author, ServiceIdentity(service: "mail", accountID: mine.id, externalID: "peer@example.invalid"))
        XCTAssertEqual(first[0].title, "Subject 1")
        XCTAssertEqual(first[0].identity.service, "mail")
        XCTAssertFalse(first[0].isOutgoing)
        let rest = try await source.items(after: first[0].sequence, limit: 200)
        XCTAssertEqual(rest.map(\.text), ["second"])
        XCTAssertTrue(rest[0].isOutgoing)
    }

    func testAccountBackfillOnlyThatAccount() async throws {
        let repository = try repository(), a = account("a@example.invalid"), b = account("b@example.invalid")
        try await repository.saveAccount(a)
        try await repository.saveAccount(b)
        try await repository.saveLetters([letter(a, uid: 1, from: "x@example.invalid", text: "for a"), letter(b, uid: 1, from: "y@example.invalid", text: "for b")])
        let source = MailAIIndexSource(repository: repository)
        let items = try await source.items(in: .mailAccount(accountID: a.id), after: 0, limit: 200)
        XCTAssertEqual(items.map(\.text), ["for a"])
        let chat = try await source.items(in: .conversation(service: "telegram", accountID: a.id, conversationID: "c"), after: 0, limit: 200)
        XCTAssertTrue(chat.isEmpty)
    }

    func testHTMLOnlyLetterBecomesPlainText() async throws {
        let repository = try repository(), mine = account("me@example.invalid")
        try await repository.saveAccount(mine)
        try await repository.saveLetters([letter(mine, uid: 3, from: "p@example.invalid", text: nil, html: "<p>Hello <b>there</b></p>")])
        let items = try await MailAIIndexSource(repository: repository).items(after: 0, limit: 200)
        XCTAssertEqual(items.first?.text.trimmingCharacters(in: .whitespacesAndNewlines), "Hello there")
    }

    func testRemovedLetterMarked() async throws {
        let repository = try repository(), mine = account("me@example.invalid")
        try await repository.saveAccount(mine)
        var value = letter(mine, uid: 4, from: "p@example.invalid", text: "gone")
        try await repository.saveLetters([value])
        value.removedFromSource = true
        try await repository.saveLetters([value])
        let items = try await MailAIIndexSource(repository: repository).items(after: 0, limit: 200)
        XCTAssertEqual(items.map(\.removed), [false, true])
    }
}

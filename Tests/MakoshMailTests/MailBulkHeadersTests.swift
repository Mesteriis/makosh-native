import CPostgres
import MakoshCore
import NIOCore
import NIOIMAPCore
import XCTest

@testable import MakoshMail

final class MailBulkHeadersTests: XCTestCase {
    private func service() -> IMAPService {
        IMAPService(
            config: MailAccount(
                displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa",
                smtpHost: "smtp.example.invalid", smtpUsername: "qa"
            ).transport, password: "synthetic")
    }

    private func fetch(uid: UInt32, headers: String?) -> [Response] {
        var responses: [Response] = [
            .fetch(.start(1)), .fetch(.simpleAttribute(.uid(UID(rawValue: uid)))),
            .fetch(
                .simpleAttribute(
                    .envelope(
                        Envelope(
                            date: nil, subject: ByteBuffer(string: "s"),
                            from: [
                                .singleAddress(
                                    .init(
                                        personName: nil, sourceRoot: nil, mailbox: ByteBuffer(string: "a"), host: ByteBuffer(string: "x.ru")
                                    ))
                            ],
                            sender: [], reply: [], to: [], cc: [], bcc: [], inReplyTo: nil, messageID: nil)))),
        ]
        if let headers {
            let bytes = ByteBuffer(string: headers)
            responses.append(
                .fetch(
                    .streamingBegin(
                        kind: .body(section: .headerFields(IMAPService.bulkHeaderFields), offset: nil), byteCount: bytes.readableBytes)))
            responses.append(.fetch(.streamingBytes(bytes)))
            responses.append(.fetch(.streamingEnd))
        }
        responses.append(.fetch(.finish))
        return responses
    }

    func testHeaderFieldsFetchSetsBulkFlags() {
        let service = service()
        let list = service.parseMessages(
            fetch(uid: 1, headers: "List-Id: Team <team.example.com>\r\nList-Unsubscribe: <mailto:u@x>\r\n\r\n"))
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].listHeaders)
        XCTAssertFalse(list[0].precedenceBulk)
        XCTAssertFalse(list[0].autoSubmitted)
        let bulk = service.parseMessages(fetch(uid: 2, headers: "Precedence: bulk\r\n\r\n"))
        XCTAssertTrue(bulk[0].precedenceBulk)
        let auto = service.parseMessages(fetch(uid: 3, headers: "Auto-Submitted: auto-generated\r\n\r\n"))
        XCTAssertTrue(auto[0].autoSubmitted)
        let manual = service.parseMessages(fetch(uid: 4, headers: "Auto-Submitted: no\r\nPrecedence: first-class\r\n\r\n"))
        XCTAssertFalse(manual[0].autoSubmitted)
        XCTAssertFalse(manual[0].precedenceBulk)
        let none = service.parseMessages(fetch(uid: 5, headers: nil))
        XCTAssertFalse(none[0].listHeaders)
        XCTAssertEqual(IMAPService.envelopeAttributes.count, 5, "the envelope fetch asks for the bulk header fields too")
    }

    func testLettersAfterSequencePages() async throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("Real PostgreSQL required") }
        let configuration = PersonWorkspaceConfiguration(
            connectionString: dsn, schema: "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        defer { Self.dropSchema(configuration.schema, dsn: dsn) }
        let repository = MailRepository(configuration: configuration, keyProvider: { _, _ in Data(repeating: 7, count: 32) })
        let account = MailAccount(
            displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa",
            smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        try await repository.saveAccount(account)
        var letters: [MailLetter] = []
        for uid in 1...250 {
            var letter = MailLetter(
                key: .init(accountID: account.id, folder: "INBOX", uidValidity: 1, uid: UInt32(uid)), subject: "s\(uid)", senderName: "A",
                sender: "a\(uid)@x.ru", recipient: account.email, date: Date(timeIntervalSince1970: TimeInterval(uid)))
            letter.listHeaders = uid % 2 == 0
            letters.append(letter)
        }
        try await repository.saveLetters(letters)
        try await repository.saveLetters([
            MailLetter(
                key: .init(accountID: account.id, folder: "Sent", uidValidity: 1, uid: 1), subject: "other", senderName: "",
                sender: account.email,
                recipient: "b@x.ru", date: Date())
        ])
        let first = try await repository.letters(accountID: account.id, folder: "INBOX", afterSequence: 0, limit: 200)
        XCTAssertEqual(first.count, 200)
        XCTAssertEqual(first.first?.key.uid, 1)
        XCTAssertEqual(first.first?.listHeaders, false)
        XCTAssertEqual(first[1].listHeaders, true)
        let last = try XCTUnwrap(first.last?.cacheSequence)
        let second = try await repository.letters(accountID: account.id, folder: "INBOX", afterSequence: last, limit: 200)
        XCTAssertEqual(second.count, 50)
        XCTAssertEqual(second.last?.key.uid, 250)
        let sent = try await repository.letters(accountID: account.id, folder: "Sent", afterSequence: 0, limit: 200)
        XCTAssertEqual(sent.count, 1)
    }

    static func dropSchema(_ schema: String, dsn: String) {
        guard schema.hasPrefix("qa_mail_"), let db = PQconnectdb(dsn), PQstatus(db) == CONNECTION_OK else { return }
        defer { PQfinish(db) }
        if let result = PQexec(db, "DROP SCHEMA IF EXISTS \"\(schema)\" CASCADE") { PQclear(result) }
    }
}

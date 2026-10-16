import XCTest
import MakoshCore
@testable import MakoshMail

final class MailReadingHistoryTests: XCTestCase {
    func testLongTextPagesPreserveEndAndGraphemeBoundaries() throws {
        let original = String(repeating: "👩🏽‍💻Привет\n", count: 30000) + "FINAL-MARKER"
        let pages = try MailTextPagination.pages(original, pageSize: 16000)
        XCTAssertGreaterThan(pages.count, 8)
        XCTAssertEqual(pages.joined(), original)
        XCTAssertTrue(pages.last?.hasSuffix("FINAL-MARKER") == true)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 16000 })
    }
    func testHistoryReturnsFullVersionsByCursorWithoutChangingCurrentLetter() async throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PostgreSQL required") }
        let configuration = ContactWorkspaceConfiguration(connectionString: dsn, schema: "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let repository = MailRepository(configuration: configuration, keyProvider: { _,_ in Data(repeating: 0x47, count: 32) })
        var letter = MailLetter(key: .init(accountID: "a", folder: "INBOX", uidValidity: 42, uid: 1), subject: "History", senderName: "QA", sender: "qa@example.invalid", recipient: "peer@example.invalid", date: Date(), text: "Original")
        try await repository.saveLetters([letter])
        letter.text = String(repeating: "Long", count: 40000) + "END"; letter.html = "<p>Changed</p>"
        try await repository.saveLetters([letter])
        var other = letter; other.key = .init(accountID: "b", folder: "INBOX", uidValidity: 42, uid: 1); other.text = "Other account"
        try await repository.saveLetters([other])
        let recent = try await repository.versions(letter.id, beforeSequence: nil, limit: 1)
        XCTAssertEqual(recent.first?.letter.text, letter.text)
        XCTAssertEqual(recent.first?.letter.html, "<p>Changed</p>")
        let older = try await repository.versions(letter.id, beforeSequence: recent.first?.id, limit: 1)
        XCTAssertEqual(older.first?.letter.text, "Original")
        let current = try await repository.letter(letter.id)
        XCTAssertEqual(current?.text, letter.text)
    }
}

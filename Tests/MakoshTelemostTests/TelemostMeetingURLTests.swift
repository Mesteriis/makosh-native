import XCTest
@testable import MakoshTelemost

final class TelemostMeetingURLTests: XCTestCase {
    func testOfficialURLAndConfusableRejection() throws {
        let valid = try TelemostMeetingURL(" https://telemost.yandex.ru/j/123 \n")
        XCTAssertEqual(valid.conferenceID, "123")
        XCTAssertEqual(valid.url.absoluteString, "https://telemost.yandex.ru/j/123")
        for value in [
            "http://telemost.yandex.ru/j/123", "https://telemost.yandex.ru.evil.example/j/123",
            "https://telemost.yandex.ru@evil.example/j/123", "https://user@telemost.yandex.ru/j/123",
            "https://telemost.yandex.ru:444/j/123", "https://telemost.yandex.ru/j/123?token=private",
            "https://telemost.yandex.ru/j/123#fragment", "https://telemost.yandex.ru/j/123/extra",
            "https://telemost.yandex.ru/j/%2f123", "https://telemost.yandex.ru/j/%2e%2e",
            "https://telemost.yandex.ru/j/..", "https://telemost.yandex.ru/j/",
            "https://telemost.yandex.ru/j/a\\b", "https://telemost.yandex.ru./j/123",
            "https://telemost.yandex.ru/j/123\nother", "https://telemost.360.yandex.ru/j/123"
        ] { XCTAssertThrowsError(try TelemostMeetingURL(value), value) }
    }

    func testByteExactScopeIdentity() throws {
        let a = TelemostScope(accountID: telemostTestAccountID, conferenceID: "\u{e9}")
        let b = TelemostScope(accountID: telemostTestAccountID, conferenceID: "e\u{301}")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.storageKey, b.storageKey)
        XCTAssertEqual(Set([a, b]).count, 2)
        XCTAssertNotEqual(a.storageKey, TelemostScope(accountID: UUID(), conferenceID: a.conferenceID).storageKey)
    }

    func testDecodedURLCannotBypassValidation() throws {
        let forged = Data(#"{"url":"https://evil.example/j/123","conferenceID":"123"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TelemostMeetingURL.self, from: forged))
    }
}

import XCTest
@testable import MakoshAI

final class AIModelsTests: XCTestCase {
    private func connection(_ url: String, name: String = "Local") -> AIConnection {
        AIConnection(id: UUID(), name: name, baseURL: URL(string: url)!)
    }

    func testHTTPSAccepted() throws {
        XCTAssertEqual(try connection("https://api.openai.com/v1").validated().baseURL.absoluteString, "https://api.openai.com/v1")
    }

    func testLoopbackHTTPAccepted() throws {
        for url in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1"] {
            XCTAssertNoThrow(try connection(url).validated(), url)
        }
    }

    func testRemoteHTTPRejected() {
        XCTAssertThrowsError(try connection("http://example.com/v1").validated()) { XCTAssertEqual($0 as? AIFailure, .invalidConnection) }
    }

    func testCredentialsQueryAndFragmentRejected() {
        for url in [
            "https://user:secret@example.com/v1", "https://example.com/v1?key=1", "https://example.com/v1#x", "ftp://example.com/v1",
        ] {
            XCTAssertThrowsError(try connection(url).validated(), url)
        }
    }

    func testEmptyNameRejected() {
        XCTAssertThrowsError(try connection("https://example.com/v1", name: "  \n").validated()) {
            XCTAssertEqual($0 as? AIFailure, .invalidConnection)
        }
    }

    func testNameTrimmedAndLimitedTo80() throws {
        XCTAssertEqual(try connection("https://example.com/v1", name: "  Cloud \n").validated().name, "Cloud")
        XCTAssertNoThrow(try connection("https://example.com/v1", name: String(repeating: "a", count: 80)).validated())
        XCTAssertThrowsError(try connection("https://example.com/v1", name: String(repeating: "a", count: 81)).validated())
    }
}

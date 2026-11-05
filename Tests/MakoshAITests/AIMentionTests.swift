import XCTest
@testable import MakoshAI

final class AIMentionTests: XCTestCase {
    func testMentionIsTheWordAfterTheLastAt() {
        XCTAssertEqual(AIMention.query(in: "сравни с @Мар"), "Мар")
        XCTAssertEqual(AIMention.query(in: "@"), "")
    }
    func testMentionEndsAtWhitespace() {
        XCTAssertNil(AIMention.query(in: "@Иван что он сказал"))
        XCTAssertNil(AIMention.query(in: "почта me@example.test"), "an address is not a mention")
    }
    func testChoosingReplacesOnlyTheMention() {
        XCTAssertEqual(AIMention.removing(from: "сравни с @Мар"), "сравни с ")
        XCTAssertEqual(AIMention.removing(from: "без упоминания"), "без упоминания")
    }
}

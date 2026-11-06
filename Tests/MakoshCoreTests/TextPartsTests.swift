import XCTest
@testable import MakoshCore

final class TextPartsTests: XCTestCase {
    func testParagraphsArePackedUpToTheSize() {
        let text = (1...5).map { "Абзац \($0) " + String(repeating: "слово ", count: 100) }.joined(separator: "\n\n")
        let parts = TextParts.split(text, size: 1_500)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 1_500 + 20 })
        XCTAssertTrue(parts.allSatisfy { $0.hasPrefix("Абзац") }, "parts start at paragraph boundaries")
        XCTAssertEqual(parts.joined(separator: "\n\n").filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
    }

    func testOversizedParagraphSplitsByLinesThenHard() {
        let lines = (1...6).map { "строка \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        let parts = TextParts.split(lines, size: 120)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 120 })
        XCTAssertTrue(parts.first?.hasPrefix("строка 1") == true)
        XCTAssertEqual(TextParts.split(String(repeating: "x", count: 10), size: 4), ["xxxx", "xxxx", "xx"])
        XCTAssertEqual(TextParts.split("   ", size: 10), [])
    }
}

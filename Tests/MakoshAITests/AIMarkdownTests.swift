import XCTest
@testable import MakoshAI

final class AIMarkdownTests: XCTestCase {
    func testFencedCodeBecomesItsOwnBlockWithLanguage() {
        let text = "До\n```swift\nlet x = 1\nprint(x)\n```\nПосле"
        XCTAssertEqual(
            AIMarkdown.blocks(text),
            [.text("До"), .code(language: "swift", code: "let x = 1\nprint(x)"), .text("После")])
    }

    func testUnclosedFenceWhileStreamingIsStillCode() {
        XCTAssertEqual(AIMarkdown.blocks("```\nlet x"), [.code(language: nil, code: "let x")])
    }

    func testHeadingsAreSeparated() {
        XCTAssertEqual(
            AIMarkdown.blocks("## Итоги\nТекст"),
            [.heading(level: 2, text: "Итоги"), .text("Текст")])
    }

    func testListsAndBlankLinesStayInTextBlocks() {
        let text = "Темы:\n\n1. **Backend**\n   - тесты\n2. Frontend"
        XCTAssertEqual(AIMarkdown.blocks(text), [.text("Темы:"), .text("1. **Backend**\n   - тесты\n2. Frontend")])
    }

    func testCodeIndentationIsKept() {
        XCTAssertEqual(AIMarkdown.blocks("```\n  a\n    b\n```"), [.code(language: nil, code: "  a\n    b")])
    }
}

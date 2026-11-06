import XCTest
@testable import MakoshAI

final class AIFileMaterialTests: XCTestCase {
    func testFallbackUsedWhenLocalTextIsThin() throws {
        let result = try AIContextDocument.assemble(
            pages: ["", "x"], pageCount: 2, paginated: true, recognizedPages: [1], truncatedOCR: false, selected: nil,
            fallback: "Текст из Paperless.\n\nВторой абзац.", source: "paperless")
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.document.source, "paperless-content")
        XCTAssertFalse(result.document.paginated, "the fallback text has no pages")
        XCTAssertEqual(result.document.pages, ["Текст из Paperless.\n\nВторой абзац."])
        XCTAssertEqual(result.document.pageCount, 1)
        XCTAssertEqual(result.document.selected, 1...1)
        XCTAssertFalse(result.document.recognized)
    }

    func testFallbackIgnoredWhenLocalTextIsEnough() throws {
        let page = String(repeating: "слово ", count: 20)
        let result = try AIContextDocument.assemble(
            pages: [page, page], pageCount: 2, paginated: true, recognizedPages: [2], truncatedOCR: true, selected: 1...2,
            fallback: "ignored", source: "paperless")
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.document.source, "paperless")
        XCTAssertEqual(result.document.pages, [page, page])
        XCTAssertTrue(result.document.recognized)
        XCTAssertTrue(result.document.truncatedOCR)
        XCTAssertEqual(result.document.selected, 1...2)
    }

    func testThinTextWithoutFallbackStaysLocal() throws {
        let result = try AIContextDocument.assemble(
            pages: ["", ""], pageCount: 2, paginated: true, recognizedPages: [], truncatedOCR: false, selected: nil, fallback: nil,
            source: "archive")
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.document.pages, ["", ""])
    }

    func testPagesOutsideDocumentAreRejected() {
        XCTAssertThrowsError(
            try AIContextDocument.assemble(
                pages: ["a"], pageCount: 3, paginated: true, recognizedPages: [], truncatedOCR: false, selected: 2...9, fallback: nil,
                source: "archive")
        ) { error in
            guard case .contextUnavailable(let reason)? = error as? AIFailure else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("3 страниц"), reason)
        }
    }

    func testFallbackRangeBeyondItsPartsUsesAllParts() throws {
        // Page 1 of a 38-page scan was chosen; the local read is blank and the Paperless text has 2 parts.
        let fallback =
            "Первая часть." + String(repeating: " слово", count: 480) + "\n\nВторая часть." + String(repeating: " слово", count: 100)
        XCTAssertEqual(AIContextDocument.parts(fallback).count, 2, "fixture: two parts")
        let result = try AIContextDocument.assemble(
            pages: [""], pageCount: 38, paginated: true, recognizedPages: [], truncatedOCR: false, selected: 1...1, fallback: fallback,
            source: "paperless")
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.document.selected, 1...1, "a range within the parts still applies")
        let wide = try AIContextDocument.assemble(
            pages: [""], pageCount: 38, paginated: true, recognizedPages: [], truncatedOCR: false, selected: 20...25, fallback: fallback,
            source: "paperless")
        XCTAssertEqual(wide.document.selected, 1...2, "a page range the parts cannot honour falls back to all parts, not an error")
        XCTAssertEqual(wide.document.pages.count, 2)
    }

    func testFallbackSelectionAppliesToParts() throws {
        let long = (1...4).map { "Абзац \($0) " + String(repeating: "т", count: 2_990) }.joined(separator: "\n\n")
        let result = try AIContextDocument.assemble(
            pages: [""], pageCount: 1, paginated: true, recognizedPages: [], truncatedOCR: false, selected: 2...3, fallback: long,
            source: "paperless")
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.document.pageCount, 4)
        XCTAssertEqual(result.document.selected, 2...3)
        XCTAssertEqual(result.document.pages.count, 2)
        XCTAssertTrue(result.document.pages[0].hasPrefix("Абзац 2"))
    }
}

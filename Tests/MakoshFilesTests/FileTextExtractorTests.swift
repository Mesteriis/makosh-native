import Foundation
import XCTest
@testable import MakoshFiles

final class FileTextExtractorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.directory()
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }
    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func testPDFTextLayerIsReadPerPage() async throws {
        let url = file("contract.pdf")
        try Fixtures.pdf([.text("Пункт первый договора"), .text("Пункт второй договора")], at: url)
        let text = try await FileTextExtractor().extract(url, name: "contract.pdf", pages: nil)
        XCTAssertEqual(text.pageCount, 2)
        XCTAssertTrue(text.paginated)
        XCTAssertEqual(text.pages.count, 2)
        XCTAssertTrue(text.pages[0].contains("Пункт первый"), text.pages[0])
        XCTAssertTrue(text.pages[1].contains("Пункт второй"), text.pages[1])
        XCTAssertEqual(text.recognizedPages, [])
        XCTAssertFalse(text.truncatedOCR)
    }

    func testScannedPageFallsBackToOCRAndIsMarked() async throws {
        let url = file("scan.pdf")
        try Fixtures.pdf([.scan("INVOICE 1234")], at: url)
        let text = try await FileTextExtractor().extract(url, name: "scan.pdf", pages: nil)
        XCTAssertEqual(text.recognizedPages, [1])
        XCTAssertTrue(text.pages[0].contains("1234"), text.pages[0])
    }

    func testMixedPDFKeepsPageOrder() async throws {
        let url = file("mixed.pdf")
        try Fixtures.pdf([.text("Страница с текстовым слоем договора"), .scan("TOTAL 5678")], at: url)
        let text = try await FileTextExtractor().extract(url, name: "mixed.pdf", pages: nil)
        XCTAssertEqual(text.pageCount, 2)
        XCTAssertTrue(text.pages[0].contains("Страница с текстовым слоем"))
        XCTAssertTrue(text.pages[1].contains("5678"), text.pages[1])
        XCTAssertEqual(text.recognizedPages, [2])
    }

    func testPageRangeLimitsWork() async throws {
        let url = file("three.pdf")
        try Fixtures.pdf([.text("один"), .text("два"), .text("три")], at: url)
        let text = try await FileTextExtractor().extract(url, name: "three.pdf", pages: 2...3)
        XCTAssertEqual(text.pageCount, 3)
        XCTAssertEqual(text.pages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, ["два", "три"])
        do {
            _ = try await FileTextExtractor().extract(url, name: "three.pdf", pages: 2...9)
            XCTFail("pages beyond the document are refused")
        } catch let error as FilesFailure { XCTAssertEqual(error, .pagesOutOfRange(pageCount: 3)) }
    }

    func testOCRLimitMarksTruncation() async throws {
        let url = file("scans.pdf")
        try Fixtures.pdf([.scan("A 1"), .scan("B 2"), .scan("C 3")], at: url)
        let text = try await FileTextExtractor(ocrPageLimit: 2).extract(url, name: "scans.pdf", pages: nil)
        XCTAssertTrue(text.truncatedOCR)
        XCTAssertEqual(text.recognizedPages, [1, 2])
        XCTAssertEqual(text.pages[2], "", "the page past the limit is empty, not invented")
    }

    func testProgressCountsPages() async throws {
        let url = file("two.pdf")
        try Fixtures.pdf([.text("a"), .text("b")], at: url)
        let seen = Collector<ExtractionProgress>()
        _ = try await FileTextExtractor().extract(url, name: "two.pdf", pages: nil) { seen.append($0) }
        XCTAssertEqual(seen.values, [ExtractionProgress(done: 1, total: 2), ExtractionProgress(done: 2, total: 2)])
    }

    func testDOCXAndRTFBecomeParts() async throws {
        let docx = file("contract.docx"), rtf = file("notes.rtf")
        try Fixtures.docx("Первый абзац.\n\nВторой абзац.", at: docx)
        try Fixtures.rtf("Заметка в RTF", at: rtf)
        let word = try await FileTextExtractor().extract(docx, name: "contract.docx", pages: nil)
        XCTAssertFalse(word.paginated)
        XCTAssertEqual(word.pageCount, 1)
        XCTAssertTrue(word.pages[0].contains("Второй абзац"), word.pages[0])
        let rich = try await FileTextExtractor().extract(rtf, name: "notes.rtf", pages: nil)
        XCTAssertTrue(rich.pages[0].contains("Заметка в RTF"))
    }

    func testCP1251TextIsDecoded() async throws {
        let url = file("old.txt")
        try "Счёт за ноябрь".data(using: .windowsCP1251)!.write(to: url)
        let text = try await FileTextExtractor().extract(url, name: "old.txt", pages: nil)
        XCTAssertEqual(text.pages, ["Счёт за ноябрь"])
        let utf = file("new.md")
        try Data("# Заголовок".utf8).write(to: utf)
        let markdown = try await FileTextExtractor().extract(utf, name: "new.md", pages: nil)
        XCTAssertEqual(markdown.pages, ["# Заголовок"])
    }

    func testImageIsRecognized() async throws {
        let url = file("photo.png")
        try Fixtures.png(text: "RECEIPT 4321", at: url)
        let text = try await FileTextExtractor().extract(url, name: "photo.png", pages: nil)
        XCTAssertFalse(text.paginated)
        XCTAssertEqual(text.recognizedPages, [1])
        XCTAssertTrue(text.pages[0].contains("4321"), text.pages[0])
    }

    func testUnsupportedKindIsRefused() async throws {
        let url = file("pack.zip")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: url)
        do {
            _ = try await FileTextExtractor().extract(url, name: "pack.zip", pages: nil)
            XCTFail("archives have no text")
        } catch let error as FilesFailure { XCTAssertEqual(error, .unsupportedText("zip")) }
    }

    func testPartsSplitOnParagraphs() {
        let text = (1...5).map { "Абзац \($0) " + String(repeating: "слово ", count: 100) }.joined(separator: "\n\n")
        let parts = FileTextExtractor.parts(text, size: 1_500)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 1_500 + 20 }, "parts stay near the size")
        XCTAssertEqual(parts.joined(separator: "\n\n").filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace }, "nothing is lost")
        XCTAssertTrue(parts.allSatisfy { $0.hasPrefix("Абзац") }, "parts start at paragraph boundaries")
        XCTAssertEqual(
            FileTextExtractor.parts(String(repeating: "x", count: 10), size: 4), ["xxxx", "xxxx", "xx"], "text without breaks is cut hard")
        XCTAssertEqual(FileTextExtractor.parts("   ", size: 10), [])
    }

    func testCancellationStopsBetweenPages() async throws {
        let url = file("many.pdf")
        try Fixtures.pdf((1...6).map { .scan("PAGE \($0)") }, at: url)
        let task = Task { try await FileTextExtractor().extract(url, name: "many.pdf", pages: nil) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled extraction does not finish")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    }

    func testCancellationAfterTheFirstPageStopsEarly() async throws {
        let url = file("scans6.pdf")
        try Fixtures.pdf((1...6).map { .scan("PAGE \($0)") }, at: url)
        let box = TaskBox()
        let seen = Collector<ExtractionProgress>()
        let task = Task {
            try await FileTextExtractor().extract(url, name: "scans6.pdf", pages: nil) { progress in
                seen.append(progress)
                box.task?.cancel()
            }
        }
        box.task = task
        do {
            _ = try await task.value
            XCTFail("the extraction stops after the page that saw the cancellation")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        XCTAssertLessThanOrEqual(seen.values.count, 2, "no more than one page after the cancellation")
    }

    func testCorruptImageIsRefusedNotCrashing() async throws {
        let url = file("broken.png")
        try Data("not an image".utf8).write(to: url)
        do {
            _ = try await FileTextExtractor().extract(url, name: "broken.png", pages: nil)
            XCTFail("a broken image is refused")
        } catch let error as FilesFailure { XCTAssertEqual(error, .unsupportedText("png")) }
    }

    func testCacheRoundTrip() async {
        let extractor = FileTextExtractor()
        let value = ExtractedText(pages: ["a"], pageCount: 1, paginated: true, recognizedPages: [], truncatedOCR: false)
        await extractor.store(value, key: "k")
        let cached = await extractor.cached(key: "k")
        XCTAssertEqual(cached, value)
        await extractor.clear()
        let cleared = await extractor.cached(key: "k")
        XCTAssertNil(cleared)
    }
}

final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Task<ExtractedText, Error>?
    var task: Task<ExtractedText, Error>? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Values collected from `@Sendable` callbacks.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ value: T) { lock.withLock { items.append(value) } }
    var values: [T] { lock.withLock { items } }
}

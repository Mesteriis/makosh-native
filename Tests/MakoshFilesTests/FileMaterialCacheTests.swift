import XCTest
@testable import MakoshFiles

final class FileMaterialCacheTests: XCTestCase {
    private func text(_ page: String) -> ExtractedText {
        ExtractedText(pages: [page], pageCount: 1, paginated: true, recognizedPages: [], truncatedOCR: false)
    }

    func testOldestEntriesAreEvictedBeyondTheLimit() async {
        let cache = FileMaterialCache(limit: 3)
        for index in 1...4 { await cache.store(.init(text: text("p\(index)"), fallback: nil), for: "card\(index)|all") }
        let first = await cache.value(for: "card1|all")
        XCTAssertNil(first, "the oldest entry left when the fourth arrived")
        let last = await cache.value(for: "card4|all")
        XCTAssertEqual(last?.text.pages, ["p4"])
    }

    func testForgettingACardDropsEveryRangeOfIt() async {
        let cache = FileMaterialCache(limit: 10)
        await cache.store(.init(text: text("a"), fallback: nil), for: "file:archive:1|all")
        await cache.store(.init(text: text("b"), fallback: "x"), for: "file:archive:1|2-3")
        await cache.store(.init(text: text("c"), fallback: nil), for: "file:archive:2|all")
        await cache.forget(cardID: "file:archive:1")
        let gone = await cache.value(for: "file:archive:1|2-3")
        XCTAssertNil(gone)
        let kept = await cache.value(for: "file:archive:2|all")
        XCTAssertEqual(kept?.text.pages, ["c"])
    }
}

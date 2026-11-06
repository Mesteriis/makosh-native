import XCTest
@testable import MakoshAI

final class AITokenEstimateTests: XCTestCase {
    func testCyrillicAndLatinEstimates() {
        XCTAssertEqual(AITokenEstimate.tokens(in: "привет"), 3, "6 Cyrillic letters at 2.5 per token")
        XCTAssertEqual(AITokenEstimate.tokens(in: "hello world"), 3, "11 other characters at 4 per token")
        XCTAssertEqual(AITokenEstimate.tokens(in: "привет мир"), 5, "9 Cyrillic → 4, one space → 1")
        XCTAssertEqual(AITokenEstimate.tokens(in: ""), 0)
    }

    func testBudgetLeavesRoomForTheAnswer() {
        XCTAssertEqual(AITokenEstimate.budget(contextTokens: nil), 108_800)
        XCTAssertEqual(AITokenEstimate.budget(contextTokens: 200_000), 170_000)
        XCTAssertEqual(AITokenEstimate.budget(contextTokens: 0), 108_800, "a zero or negative setting falls back to the default")
    }
}

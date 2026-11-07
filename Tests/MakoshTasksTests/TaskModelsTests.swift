import Foundation
import XCTest
@testable import MakoshTasks

final class TaskModelsTests: XCTestCase {
    func testCodeIsFiveCrockfordCharacters() {
        let code = TaskCode.make(from: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        XCTAssertEqual(code.count, 5)
        XCTAssertTrue(code.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        let other = TaskCode.make(from: UUID(uuidString: "ffffffff-0000-0000-0000-000000000000")!)
        XCTAssertNotEqual(code, other, "different leading bits give different codes")
    }

    func testStatusCycleOrder() { XCTAssertEqual(TaskStatus.allCases, [.inbox, .active, .done, .cancelled]) }
}

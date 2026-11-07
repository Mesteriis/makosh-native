import Foundation
import XCTest
@testable import MakoshJira

final class JiraModelsTests: XCTestCase {
    func testStatusCategoryDecodesUnknownAsUndefined() throws {
        let data = Data(#"{"id":"1","name":"X","category":"weird"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(JiraStatus.self, from: data).category, .undefined)
        let done = Data(#"{"id":"3","name":"Done","category":"done"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(JiraStatus.self, from: done).category, .done)
    }
}

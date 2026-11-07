import Foundation
import XCTest

/// The Jira transfer pin names its source revision and the files it carries.
final class DependencyLockTests: XCTestCase {
    private struct DependencyLock: Decodable {
        struct Source: Decodable {
            let url: String
            let revision: String
            let license: String
        }
        struct File: Decodable {
            let path: String
            let sha256: String
        }
        let schemaVersion: Int
        let source: Source
        let files: [File]
    }

    func testJiraLockNamesTheMacTowerRevision() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Dependencies/Jira.lock.json")
        let lock = try JSONDecoder().decode(DependencyLock.self, from: Data(contentsOf: url))
        XCTAssertEqual(lock.schemaVersion, 1)
        XCTAssertEqual(lock.source.revision.count, 40)
        XCTAssertTrue(lock.source.revision.hasPrefix("317eeaf"))
        XCTAssertEqual(lock.source.license, "MIT")
        XCTAssertFalse(lock.files.isEmpty)
        for file in lock.files {
            XCTAssertEqual(file.sha256.count, 64, file.path)
            XCTAssertTrue(file.path.hasPrefix("src/MacTowerWorkTracking/"), file.path)
        }
    }
}

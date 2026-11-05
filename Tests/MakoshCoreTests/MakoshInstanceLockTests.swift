import Foundation
import XCTest
@testable import MakoshCore

final class MakoshInstanceLockTests: XCTestCase {
    func testSecondInstanceIsRefusedUntilTheFirstReleases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("org.makosh.desktop.lock")
        var first = MakoshInstanceLock.acquire(at: url)
        XCTAssertNotNil(first)
        XCTAssertNil(MakoshInstanceLock.acquire(at: url))
        let other = MakoshInstanceLock.acquire(at: directory.appendingPathComponent("org.makosh.ai.qa.lock"))
        XCTAssertNotNil(other, "a separately identified QA bundle has its own lock")
        first = nil
        XCTAssertNotNil(MakoshInstanceLock.acquire(at: url))
        _ = other
    }
}

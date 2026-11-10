import Foundation
import XCTest
@testable import MakoshCore

final class MakoshInstanceLockTests: XCTestCase {
    func testSecondInstanceIsRefusedUntilTheFirstReleases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("org.makosh.desktop.lock")
        var first: MakoshInstanceLock?
        if case .acquired(let lock) = MakoshInstanceLock.acquire(at: url) { first = lock }
        XCTAssertNotNil(first, "the first copy takes the lock")
        guard case .heldByOther = MakoshInstanceLock.acquire(at: url) else { return XCTFail("a second copy is refused") }
        guard case .acquired = MakoshInstanceLock.acquire(at: directory.appendingPathComponent("org.makosh.ai.qa.lock")) else {
            return XCTFail("a separately identified QA bundle has its own lock")
        }
        first = nil
        guard case .acquired = MakoshInstanceLock.acquire(at: url) else { return XCTFail("the released lock is free again") }
    }

    /// A lock that cannot be created is not a lock held by another copy: the app
    /// must keep launching instead of quietly quitting.
    func testUnwritableLocationFailsInsteadOfLookingHeld() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: directory)  // a file where the directory should be
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        guard case .failed(let code) = MakoshInstanceLock.acquire(at: directory.appendingPathComponent("org.makosh.desktop.lock")) else {
            return XCTFail("an unwritable lock location is a failure, not another copy")
        }
        XCTAssertEqual(code, ENOTDIR)
    }
}

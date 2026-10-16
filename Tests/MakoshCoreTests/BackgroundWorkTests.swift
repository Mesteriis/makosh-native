import XCTest
@testable import MakoshCore

@MainActor final class BackgroundWorkTests: XCTestCase {
    func testBlockedWorkLeavesMainActorAvailable() async throws {
        let started = expectation(description: "worker entered")
        let release = DispatchSemaphore(value: 0)
        let operation = Task {
            try await BackgroundWork.run {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 2)
        // This continuation runs on MainActor while the worker is still blocked.
        release.signal()
        let value = try await operation.value
        XCTAssertEqual(value, 42)
    }

    func testCancellationRejectsResultOfInFlightWork() async {
        let started = expectation(description: "worker entered")
        let release = DispatchSemaphore(value: 0)
        let operation = Task {
            try await BackgroundWork.run {
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel(); release.signal()
        do { _ = try await operation.value; XCTFail("Cancelled work must not publish") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error type") }
    }
}

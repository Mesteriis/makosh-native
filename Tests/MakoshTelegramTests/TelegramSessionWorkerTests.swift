import XCTest
import Darwin
@testable import MakoshTelegram

@MainActor final class TelegramSessionWorkerTests: XCTestCase {
    func testPreparationRunsKeyLookupOffMainAndPublishesEncryptedParameters() async throws {
        let root = try directory(), target = root.appendingPathComponent("session")
        let entered = expectation(description: "key lookup"), gate = DispatchSemaphore(value: 0)
        let worker = TelegramSessionWorker(directory: target, readKey: { _ in
            XCTAssertFalse(Thread.isMainThread); entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return Data(repeating: 0x73, count: 48)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let operation = Task { try await worker.prepare() }
        await fulfillment(of: [entered], timeout: 2)
        gate.signal()
        let prepared = try await operation.value
        XCTAssertEqual(prepared.directory, target)
        XCTAssertTrue(try prepared.encryption.forceEncryptionIfNoSet)
        XCTAssertEqual(try prepared.encryption.key.data, Data(repeating: 0x73, count: 32))
        XCTAssertEqual(try prepared.encryption.salt.data, Data(repeating: 0x73, count: 16))
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testCancelledPreparationDoesNotCreateCacheDirectory() async throws {
        let root = try directory(), target = root.appendingPathComponent("session")
        let entered = expectation(description: "key lookup"), gate = DispatchSemaphore(value: 0)
        let worker = TelegramSessionWorker(directory: target, readKey: { _ in
            entered.fulfill(); XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return Data(repeating: 0x74, count: 48)
        })
        let operation = Task { try await worker.prepare() }
        await fulfillment(of: [entered], timeout: 2)
        operation.cancel(); gate.signal()
        do { _ = try await operation.value; XCTFail("Cancelled preparation must not publish") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testInvalidKeyIsRefusedBeforeCacheCreation() async throws {
        let root = try directory(), target = root.appendingPathComponent("session")
        let worker = TelegramSessionWorker(directory: target, readKey: { _ in Data(repeating: 0, count: 47) })
        do { _ = try await worker.prepare(); XCTFail("Invalid key must fail closed") }
        catch { XCTAssertTrue(error is TelegramSetupError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-session-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}

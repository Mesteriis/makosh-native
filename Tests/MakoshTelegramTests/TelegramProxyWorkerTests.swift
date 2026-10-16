import XCTest
import Security
@testable import MakoshTelegram

@MainActor final class TelegramProxyWorkerTests: XCTestCase {
    func testDelayedReadRunsOffMainThreadAndAllowsMainActorProgress() async throws {
        let probe = ProxyBlockingProbe()
        let vault = TelegramProxyVault(lookup: { _ in probe.lookup() }, add: { _ in errSecAuthFailed }, update: { _, _ in errSecAuthFailed })
        let task = Task { try await vault.read() }
        await fulfillment(of: [probe.started], timeout: 2)
        probe.markMainActorProgressAndRelease()
        let record = try await task.value
        XCTAssertNil(record.token)
        XCTAssertFalse(probe.wasMainThread, "Keychain lookup must not execute on the main thread")
        XCTAssertTrue(probe.sawProgressBeforeReturning, "A delayed lookup must allow MainActor work before it returns")
    }

    func testDelayedSaveRunsOffMainThreadAndAllowsMainActorProgress() async throws {
        let probe = ProxyBlockingProbe()
        let vault = TelegramProxyVault(lookup: { _ in probe.savedLookup() }, add: { item in probe.save(item) }, update: { _, _ in errSecAuthFailed })
        let task = Task { try await vault.save(.init(), expected: .init(configuration: .init(), token: nil)) }
        await fulfillment(of: [probe.started], timeout: 2)
        probe.markMainActorProgressAndRelease()
        let record = try await task.value
        XCTAssertEqual(record.token?.count, 16)
        XCTAssertFalse(probe.wasMainThread, "Keychain save must not execute on the main thread")
        XCTAssertTrue(probe.sawProgressBeforeReturning, "A delayed save must allow MainActor work before confirmation")
    }
    func testSaveConfirmationAndConcurrentReadAreOneSerializedWorkerJob() async throws {
        let probe = ProxySerializationProbe()
        let vault = TelegramProxyVault(lookup: { _ in probe.lookup() }, add: { probe.add($0) }, update: { _, _ in errSecAuthFailed })
        let save = Task { try await vault.save(.init(), expected: .init(configuration: .init(), token: nil)) }
        await fulfillment(of: [probe.started], timeout: 2)
        let read = Task { try await vault.read() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(probe.events, ["add"])
        probe.release()
        let saved = try await save.value, fresh = try await read.value
        XCTAssertEqual(saved, fresh); XCTAssertEqual(probe.events, ["add", "lookup", "lookup"])
    }

}

private final class ProxyBlockingProbe: @unchecked Sendable {
    let started = XCTestExpectation(description: "Synthetic Keychain operation started")
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var mainThread = false, progressed = false, sawProgress = false
    private var item: [String: Any]?
    var wasMainThread: Bool { lock.withLock { mainThread } }
    var sawProgressBeforeReturning: Bool { lock.withLock { sawProgress } }
    func markMainActorProgressAndRelease() {
        lock.withLock { progressed = true }; gate.signal()
    }
    private func block() {
        lock.withLock { mainThread = Thread.isMainThread }
        started.fulfill()
        _ = gate.wait(timeout: .now() + 0.3)
        lock.withLock { sawProgress = progressed }
    }
    func lookup() -> (OSStatus, [String: Any]?) { block(); return (errSecItemNotFound, nil) }
    func save(_ value: [String: Any]) -> OSStatus { block(); lock.withLock { item = value }; return errSecSuccess }
    func savedLookup() -> (OSStatus, [String: Any]?) { lock.withLock { item.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) } }
}

private final class ProxySerializationProbe: @unchecked Sendable {
    let started = XCTestExpectation(description: "Serialized save started")
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var item: [String: Any]?, order: [String] = []
    var events: [String] { lock.withLock { order } }
    func add(_ value: [String: Any]) -> OSStatus {
        lock.withLock { order.append("add") }; started.fulfill()
        _ = gate.wait(timeout: .now() + 5)
        lock.withLock { item = value }; return errSecSuccess
    }
    func lookup() -> (OSStatus, [String: Any]?) {
        lock.withLock {
            order.append("lookup")
            return item.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }
    func release() { gate.signal() }
}

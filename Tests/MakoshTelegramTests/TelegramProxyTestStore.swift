import Foundation
import Security
import XCTest
@testable import MakoshTelegram

final class TelegramProxyTestStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedItem: [String: Any]?
    private var locked = false, updateFailure = false, writeCount = 0
    var item: [String: Any]? { get { lock.withLock { storedItem } } set { lock.withLock { storedItem = newValue } } }
    var unavailable: Bool { get { lock.withLock { locked } } set { lock.withLock { locked = newValue } } }
    var failedUpdate: Bool { get { lock.withLock { updateFailure } } set { lock.withLock { updateFailure = newValue } } }
    var writes: Int { lock.withLock { writeCount } }
    func lookup(_ query: [String: Any]) -> (OSStatus, [String: Any]?) {
        lock.withLock {
            if locked { return (errSecInteractionNotAllowed, nil) }
            return storedItem.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }
    func add(_ item: [String: Any]) -> OSStatus {
        lock.withLock {
            guard storedItem == nil else { return errSecDuplicateItem }
            writeCount += 1; storedItem = item; return errSecSuccess
        }
    }
    func update(_ query: [String: Any], _ value: [String: Any]) -> OSStatus {
        lock.withLock {
            if updateFailure { return errSecAuthFailed }
            guard let old = storedItem, let expected = query[kSecAttrGeneric as String] as? Data,
                  expected == old[kSecAttrGeneric as String] as? Data else { return errSecItemNotFound }
            writeCount += 1; for (key, value) in value { storedItem?[key] = value }; return errSecSuccess
        }
    }
    func vault() -> TelegramProxyVault { .init(lookup: lookup, add: add, update: update) }
}

@MainActor func telegramProxyAssertThrows<Value>(
    _ operation: () async throws -> Value, file: StaticString = #filePath, line: UInt = #line
) async {
    do { _ = try await operation(); XCTFail("Expected proxy validation to fail", file: file, line: line) }
    catch {}
}

final class TelegramProxyOperationGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "Delayed synthetic proxy operation")
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func pauseIfArmed() {
        let pause = lock.withLock { let value = armed; armed = false; return value }
        guard pause else { return }
        started.fulfill(); _ = gate.wait(timeout: .now() + 5)
    }
    func release() { gate.signal() }
}

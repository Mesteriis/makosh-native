import Security
import XCTest
@testable import MakoshAI

private final class MemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: Data] = [:]
    var failure: OSStatus?
    var access: AIKeychainAccess {
        AIKeychainAccess(
            read: { id in
                self.locked {
                    self.failure.map { ($0, nil) } ?? (self.items[id] == nil ? (errSecItemNotFound, nil) : (errSecSuccess, self.items[id]))
                }
            },
            write: { id, data in
                self.locked {
                    if let failure = self.failure { return failure }
                    self.items[id] = data
                    return errSecSuccess
                }
            },
            remove: { id in self.locked { self.items.removeValue(forKey: id) == nil ? errSecItemNotFound : errSecSuccess } })
    }
    var count: Int { locked { items.count } }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class AITokenVaultTests: XCTestCase {
    func testRoundTrip() async throws {
        let keychain = MemoryKeychain(), vault = AITokenVault(access: keychain.access), id = UUID()
        try await vault.save("sk-test", connectionID: id)
        let loaded = try await vault.load(connectionID: id)
        XCTAssertEqual(loaded, "sk-test")
        let missing = try await vault.load(connectionID: UUID())
        XCTAssertNil(missing)
    }

    func testTokenTrimmed() async throws {
        let keychain = MemoryKeychain(), vault = AITokenVault(access: keychain.access), id = UUID()
        try await vault.save("  sk-abc\n", connectionID: id)
        let loaded = try await vault.load(connectionID: id)
        XCTAssertEqual(loaded, "sk-abc")
    }

    func testEmptyTokenRemovesItem() async throws {
        let keychain = MemoryKeychain(), vault = AITokenVault(access: keychain.access), id = UUID()
        try await vault.save("sk-abc", connectionID: id)
        try await vault.save(" \n", connectionID: id)
        XCTAssertEqual(keychain.count, 0)
        let loaded = try await vault.load(connectionID: id)
        XCTAssertNil(loaded)
    }

    func testOversizeRejected() async {
        let keychain = MemoryKeychain(), vault = AITokenVault(access: keychain.access)
        do {
            try await vault.save(String(repeating: "a", count: 16 * 1024 + 1), connectionID: UUID())
            XCTFail("oversize token accepted")
        } catch { XCTAssertEqual(error as? AIFailure, .keyUnavailable) }
        XCTAssertEqual(keychain.count, 0)
    }

    func testKeychainErrorIsKeyUnavailable() async {
        let keychain = MemoryKeychain(), vault = AITokenVault(access: keychain.access)
        keychain.failure = errSecInteractionNotAllowed
        do {
            _ = try await vault.load(connectionID: UUID())
            XCTFail("keychain failure ignored")
        } catch { XCTAssertEqual(error as? AIFailure, .keyUnavailable) }
    }
}

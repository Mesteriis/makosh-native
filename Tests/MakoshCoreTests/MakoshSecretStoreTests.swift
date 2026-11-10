import Foundation
import Security
import XCTest
@testable import MakoshCore

/// An in-memory stand-in for the login Keychain that counts reads, so the
/// tests can prove the shared item is read once per process.
final class FakeSecretKeychain: MakoshSecretKeychain, @unchecked Sendable {
    let lock = NSLock()
    var blob: Data?
    var blobStatus: OSStatus = errSecSuccess
    var blobReads = 0
    var legacy: [String: MakoshSecret] = [:]
    var legacyReads: [String] = []
    var legacyDeletes: [String] = []
    /// Runs once, after the next read returns: another process gets its turn
    /// between a store's read and its write.
    var afterReadBlob: (@Sendable () -> Void)?
    func readBlob() -> (OSStatus, Data?) {
        let result: (OSStatus, Data?) = lock.withLock {
            blobReads += 1
            if blobStatus != errSecSuccess { return (blobStatus, nil) }
            return blob.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
        let hook: (@Sendable () -> Void)? = lock.withLock {
            defer { afterReadBlob = nil }
            return afterReadBlob
        }
        hook?()
        return result
    }
    func writeBlob(_ data: Data) -> OSStatus {
        lock.withLock {
            blob = data
            return errSecSuccess
        }
    }
    func readLegacy(service: String, account: String) -> (OSStatus, MakoshSecret?) {
        lock.withLock {
            legacyReads.append(service + "/" + account)
            return legacy[service + "/" + account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }
    func deleteLegacy(service: String, account: String) -> OSStatus {
        lock.withLock {
            legacyDeletes.append(service + "/" + account)
            return legacy.removeValue(forKey: service + "/" + account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

final class MakoshSecretStoreTests: XCTestCase {
    private let key = MakoshSecret(data: Data(repeating: 7, count: 32))
    /// One lock file per test, as every process shares one in Application Support.
    private let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-secrets-\(UUID().uuidString).lock")

    override func tearDown() {
        try? FileManager.default.removeItem(at: lockURL)
        super.tearDown()
    }

    private func makeStore(_ keychain: any MakoshSecretKeychain) -> MakoshSecretStore {
        MakoshSecretStore(keychain: keychain, lockURL: lockURL)
    }

    func testManyServicesReadTheSharedItemOnce() {
        let keychain = FakeSecretKeychain()
        let store = makeStore(keychain)
        XCTAssertEqual(store.add(service: "org.makosh.a", account: "1", secret: key), errSecSuccess)
        let afterWrite = keychain.blobReads
        for service in ["org.makosh.a", "org.makosh.b", "org.makosh.c"] { _ = store.read(service: service, account: "1") }
        XCTAssertEqual(keychain.blobReads, afterWrite, "reads are served from memory")
        let reopened = makeStore(keychain)
        XCTAssertEqual(reopened.read(service: "org.makosh.a", account: "1").1, key)
        XCTAssertEqual(reopened.read(service: "org.makosh.a", account: "1").1, key)
        XCTAssertEqual(keychain.blobReads, afterWrite + 1, "a new process reads the shared item once")
    }

    func testLegacyItemMigratesOnceAndStaysInPlace() {
        let keychain = FakeSecretKeychain()
        keychain.legacy["org.makosh.message-archive/v"] = key
        let store = makeStore(keychain)
        XCTAssertEqual(store.read(service: "org.makosh.message-archive", account: "v").1, key)
        XCTAssertEqual(makeStore(keychain).read(service: "org.makosh.message-archive", account: "v").1, key)
        XCTAssertEqual(keychain.legacyReads, ["org.makosh.message-archive/v"])
        XCTAssertNotNil(keychain.legacy["org.makosh.message-archive/v"], "legacy items are kept as a fallback")
    }

    func testDeniedSharedItemFailsClosed() {
        let keychain = FakeSecretKeychain()
        keychain.legacy["org.makosh.message-archive/v"] = key
        keychain.blobStatus = errSecAuthFailed
        let store = makeStore(keychain)
        // A refused prompt must never look like a missing key, or a new key would replace the archive's.
        XCTAssertEqual(store.read(service: "org.makosh.message-archive", account: "v").0, errSecAuthFailed)
        XCTAssertEqual(store.add(service: "org.makosh.new", account: "v", secret: key), errSecAuthFailed)
        XCTAssertTrue(keychain.legacyReads.isEmpty)
    }

    func testDeletedSecretDoesNotReturnFromLegacy() {
        let keychain = FakeSecretKeychain()
        keychain.legacy["org.makosh.ai.tokens.v1/c"] = key
        let store = makeStore(keychain)
        XCTAssertEqual(store.delete(service: "org.makosh.ai.tokens.v1", account: "c"), errSecSuccess)
        XCTAssertEqual(keychain.legacyDeletes, ["org.makosh.ai.tokens.v1/c"])
        keychain.legacy["org.makosh.ai.tokens.v1/c"] = key
        XCTAssertEqual(makeStore(keychain).read(service: "org.makosh.ai.tokens.v1", account: "c").0, errSecItemNotFound)
        XCTAssertEqual(store.delete(service: "org.makosh.ai.tokens.v1", account: "c"), errSecItemNotFound)
    }

    func testAddUpdateFollowKeychainSemantics() {
        let store = makeStore(FakeSecretKeychain())
        let other = MakoshSecret(data: Data("x".utf8))
        XCTAssertEqual(store.update(service: "s", account: "a", secret: other), errSecItemNotFound)
        XCTAssertEqual(store.add(service: "s", account: "a", secret: key), errSecSuccess)
        XCTAssertEqual(store.add(service: "s", account: "a", secret: other), errSecDuplicateItem)
        XCTAssertEqual(store.update(service: "s", account: "a", secret: other), errSecSuccess)
        XCTAssertEqual(store.read(service: "s", account: "a").1, other)
    }

    func testConditionalUpdateMatchesGenericAttribute() {
        let store = makeStore(FakeSecretKeychain())
        let first = MakoshSecret(data: Data("1".utf8), generic: Data([1]))
        XCTAssertEqual(store.add(service: "p", account: "settings", secret: first), errSecSuccess)
        let next = MakoshSecret(data: Data("2".utf8), generic: Data([2]))
        XCTAssertEqual(store.update(service: "p", account: "settings", secret: next, matchingGeneric: Data([9])), errSecItemNotFound)
        XCTAssertEqual(store.update(service: "p", account: "settings", secret: next, matchingGeneric: Data([1])), errSecSuccess)
        XCTAssertEqual(store.read(service: "p", account: "settings").1, next)
    }

    func testWriteKeepsAnotherProcessesNewerEntries() {
        let keychain = FakeSecretKeychain()
        let first = makeStore(keychain)
        let second = makeStore(keychain)
        _ = first.read(service: "s", account: "a")
        _ = second.add(service: "s", account: "b", secret: key)
        XCTAssertEqual(first.add(service: "s", account: "a", secret: key), errSecSuccess)
        let reopened = makeStore(keychain)
        XCTAssertEqual(reopened.read(service: "s", account: "b").1, key)
        XCTAssertEqual(reopened.read(service: "s", account: "a").1, key)
    }

    /// The second process writes between the first one's read and write; the
    /// lock file makes it wait, so neither entry is lost.
    func testConcurrentProcessWritesAreSerializedByTheLockFile() {
        let keychain = FakeSecretKeychain()
        let first = makeStore(keychain)
        let second = makeStore(keychain)
        XCTAssertEqual(first.read(service: "s", account: "a").0, errSecItemNotFound, "the first process has its cache filled")
        let finished = expectation(description: "the second process wrote")
        let secondStatus = StatusBox()
        let key = key
        keychain.afterReadBlob = {
            DispatchQueue.global().async {
                secondStatus.value = second.add(service: "s", account: "b", secret: key)
                finished.fulfill()
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(first.add(service: "s", account: "a", secret: key), errSecSuccess)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(secondStatus.value, errSecSuccess)
        let reopened = makeStore(keychain)
        XCTAssertEqual(reopened.read(service: "s", account: "b").1, key, "the other process's entry survives the first one's write")
        XCTAssertEqual(reopened.read(service: "s", account: "a").1, key)
    }

    func testAddRefusesAnEntryAnotherProcessWroteSinceTheCacheWasFilled() {
        let keychain = FakeSecretKeychain()
        let first = makeStore(keychain)
        XCTAssertEqual(first.read(service: "s", account: "a").0, errSecItemNotFound, "the first process has its cache filled")
        XCTAssertEqual(makeStore(keychain).add(service: "s", account: "a", secret: key), errSecSuccess)
        let other = MakoshSecret(data: Data("x".utf8))
        XCTAssertEqual(first.add(service: "s", account: "a", secret: other), errSecDuplicateItem)
        XCTAssertEqual(first.read(service: "s", account: "a").1, key, "the first writer's secret is kept and the cache sees it")
        XCTAssertEqual(makeStore(keychain).read(service: "s", account: "a").1, key)
    }

    func testUnusableLockFileFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: directory)  // a file where the directory should be
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let keychain = FakeSecretKeychain()
        let store = MakoshSecretStore(keychain: keychain, lockURL: directory.appendingPathComponent("secrets.lock"))
        XCTAssertEqual(store.add(service: "s", account: "a", secret: key), errSecIO)
        XCTAssertNil(keychain.blob, "nothing is written without the lock")
    }

    func testSecItemShapedAdaptersKeepServiceSemantics() {
        let store = makeStore(FakeSecretKeychain())
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.makosh.telegram.proxy",
            kSecAttrAccount as String: "settings.v1", kSecAttrSynchronizable as String: false,
        ]
        var item = query
        item[kSecValueData as String] = Data("1".utf8)
        item[kSecAttrGeneric as String] = Data([1])
        XCTAssertEqual(store.addItem(item), errSecSuccess)
        XCTAssertEqual(store.addItem(item), errSecDuplicateItem)
        XCTAssertEqual(store.copyData(query).1, Data("1".utf8))
        let attributes = store.copyAttributes(query).1
        XCTAssertEqual(attributes?[kSecAttrGeneric as String] as? Data, Data([1]))
        XCTAssertEqual(attributes?[kSecValueData as String] as? Data, Data("1".utf8))
        var stale = query
        stale[kSecAttrGeneric as String] = Data([9])
        XCTAssertEqual(store.updateItem(stale, [kSecValueData as String: Data("2".utf8)]), errSecItemNotFound)
        var current = query
        current[kSecAttrGeneric as String] = Data([1])
        XCTAssertEqual(
            store.updateItem(current, [kSecValueData as String: Data("2".utf8), kSecAttrGeneric as String: Data([2])]), errSecSuccess)
        XCTAssertEqual(store.copyAttributes(query).1?[kSecAttrGeneric as String] as? Data, Data([2]))
        // An update without a new generic keeps the stored one.
        XCTAssertEqual(store.updateItem(query, [kSecValueData as String: Data("3".utf8)]), errSecSuccess)
        XCTAssertEqual(store.copyAttributes(query).1?[kSecAttrGeneric as String] as? Data, Data([2]))
        XCTAssertEqual(store.deleteItem(query), errSecSuccess)
        XCTAssertEqual(store.copyData(query).0, errSecItemNotFound)
        XCTAssertEqual(store.copyData([kSecAttrService as String: "x"]).0, errSecParam)
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OSStatus?
    var value: OSStatus? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

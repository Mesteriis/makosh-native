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
    func readBlob() -> (OSStatus, Data?) {
        lock.withLock {
            blobReads += 1
            if blobStatus != errSecSuccess { return (blobStatus, nil) }
            return blob.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
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

    func testManyServicesReadTheSharedItemOnce() {
        let keychain = FakeSecretKeychain()
        let store = MakoshSecretStore(keychain: keychain)
        XCTAssertEqual(store.add(service: "org.makosh.a", account: "1", secret: key), errSecSuccess)
        let afterWrite = keychain.blobReads
        for service in ["org.makosh.a", "org.makosh.b", "org.makosh.c"] { _ = store.read(service: service, account: "1") }
        XCTAssertEqual(keychain.blobReads, afterWrite, "reads are served from memory")
        let reopened = MakoshSecretStore(keychain: keychain)
        XCTAssertEqual(reopened.read(service: "org.makosh.a", account: "1").1, key)
        XCTAssertEqual(reopened.read(service: "org.makosh.a", account: "1").1, key)
        XCTAssertEqual(keychain.blobReads, afterWrite + 1, "a new process reads the shared item once")
    }

    func testLegacyItemMigratesOnceAndStaysInPlace() {
        let keychain = FakeSecretKeychain()
        keychain.legacy["org.makosh.message-archive/v"] = key
        let store = MakoshSecretStore(keychain: keychain)
        XCTAssertEqual(store.read(service: "org.makosh.message-archive", account: "v").1, key)
        XCTAssertEqual(MakoshSecretStore(keychain: keychain).read(service: "org.makosh.message-archive", account: "v").1, key)
        XCTAssertEqual(keychain.legacyReads, ["org.makosh.message-archive/v"])
        XCTAssertNotNil(keychain.legacy["org.makosh.message-archive/v"], "legacy items are kept as a fallback")
    }

    func testDeniedSharedItemFailsClosed() {
        let keychain = FakeSecretKeychain()
        keychain.legacy["org.makosh.message-archive/v"] = key
        keychain.blobStatus = errSecAuthFailed
        let store = MakoshSecretStore(keychain: keychain)
        // A refused prompt must never look like a missing key, or a new key would replace the archive's.
        XCTAssertEqual(store.read(service: "org.makosh.message-archive", account: "v").0, errSecAuthFailed)
        XCTAssertEqual(store.add(service: "org.makosh.new", account: "v", secret: key), errSecAuthFailed)
        XCTAssertTrue(keychain.legacyReads.isEmpty)
    }

    func testDeletedSecretDoesNotReturnFromLegacy() {
        let keychain = FakeSecretKeychain()
        keychain.legacy["org.makosh.ai.tokens.v1/c"] = key
        let store = MakoshSecretStore(keychain: keychain)
        XCTAssertEqual(store.delete(service: "org.makosh.ai.tokens.v1", account: "c"), errSecSuccess)
        XCTAssertEqual(keychain.legacyDeletes, ["org.makosh.ai.tokens.v1/c"])
        keychain.legacy["org.makosh.ai.tokens.v1/c"] = key
        XCTAssertEqual(MakoshSecretStore(keychain: keychain).read(service: "org.makosh.ai.tokens.v1", account: "c").0, errSecItemNotFound)
        XCTAssertEqual(store.delete(service: "org.makosh.ai.tokens.v1", account: "c"), errSecItemNotFound)
    }

    func testAddUpdateFollowKeychainSemantics() {
        let store = MakoshSecretStore(keychain: FakeSecretKeychain())
        let other = MakoshSecret(data: Data("x".utf8))
        XCTAssertEqual(store.update(service: "s", account: "a", secret: other), errSecItemNotFound)
        XCTAssertEqual(store.add(service: "s", account: "a", secret: key), errSecSuccess)
        XCTAssertEqual(store.add(service: "s", account: "a", secret: other), errSecDuplicateItem)
        XCTAssertEqual(store.update(service: "s", account: "a", secret: other), errSecSuccess)
        XCTAssertEqual(store.read(service: "s", account: "a").1, other)
    }

    func testConditionalUpdateMatchesGenericAttribute() {
        let store = MakoshSecretStore(keychain: FakeSecretKeychain())
        let first = MakoshSecret(data: Data("1".utf8), generic: Data([1]))
        XCTAssertEqual(store.add(service: "p", account: "settings", secret: first), errSecSuccess)
        let next = MakoshSecret(data: Data("2".utf8), generic: Data([2]))
        XCTAssertEqual(store.update(service: "p", account: "settings", secret: next, matchingGeneric: Data([9])), errSecItemNotFound)
        XCTAssertEqual(store.update(service: "p", account: "settings", secret: next, matchingGeneric: Data([1])), errSecSuccess)
        XCTAssertEqual(store.read(service: "p", account: "settings").1, next)
    }

    func testWriteKeepsAnotherProcessesNewerEntries() {
        let keychain = FakeSecretKeychain()
        let first = MakoshSecretStore(keychain: keychain)
        let second = MakoshSecretStore(keychain: keychain)
        _ = first.read(service: "s", account: "a")
        _ = second.add(service: "s", account: "b", secret: key)
        XCTAssertEqual(first.add(service: "s", account: "a", secret: key), errSecSuccess)
        let reopened = MakoshSecretStore(keychain: keychain)
        XCTAssertEqual(reopened.read(service: "s", account: "b").1, key)
        XCTAssertEqual(reopened.read(service: "s", account: "a").1, key)
    }

    func testSecItemShapedAdaptersKeepServiceSemantics() {
        let store = MakoshSecretStore(keychain: FakeSecretKeychain())
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

import XCTest
import Security
@testable import MakoshCore

final class MessageArchiveKeychainTests: XCTestCase {
    func testBackupLookupDistinguishesMissingFromLockedAndMalformedExistingItems() throws {
        let id = UUID(), key = Data(repeating: 0x42, count: 32)
        XCTAssertEqual(try MessageArchiveKeychain.existing(vaultID: id, lookup: { _ in (errSecSuccess, key) }), key)
        XCTAssertNil(try MessageArchiveKeychain.existing(vaultID: id, lookup: { _ in (errSecItemNotFound, nil) }))
        for status in [errSecInteractionNotAllowed, errSecAuthFailed] {
            XCTAssertThrowsError(try MessageArchiveKeychain.existing(vaultID: id, lookup: { _ in (status, nil) }))
        }
        XCTAssertThrowsError(try MessageArchiveKeychain.existing(vaultID: id, lookup: { _ in (errSecSuccess, Data([1])) }))
    }
    func testBackupKeyImportAddsOnlyMissingExactKeyAndNeverReplacesDifferentOrLockedItem() throws {
        let id = UUID(), key = Data(repeating: 0x42, count: 32)
        var adds = 0
        try MessageArchiveKeychain.install(vaultID: id, key: key, lookup: { _ in (errSecItemNotFound, nil) }, add: { value in
            adds += 1
            XCTAssertEqual(value[kSecValueData as String] as? Data, key)
            XCTAssertEqual(value[kSecAttrSynchronizable as String] as? Bool, false)
            return errSecSuccess
        })
        XCTAssertEqual(adds, 1)
        try MessageArchiveKeychain.install(vaultID: id, key: key, lookup: { _ in (errSecSuccess, key) }, add: { _ in XCTFail("No replacement"); return errSecSuccess })
        for status in [errSecSuccess, errSecInteractionNotAllowed] {
            XCTAssertThrowsError(try MessageArchiveKeychain.install(vaultID: id, key: key, lookup: { _ in (status, Data(repeating: 0x43, count: 32)) },
                add: { _ in XCTFail("No replacement"); return errSecSuccess }))
        }
    }
    func testBackupDuplicateImportRequiresExactRereadAndInvalidInputNeverTouchesKeychain() {
        let key = Data(repeating: 0x42, count: 32)
        for matching in [true, false] {
            var reads = 0
            do {
                try MessageArchiveKeychain.install(vaultID: UUID(), key: key, lookup: { _ in
                    reads += 1
                    return reads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, matching ? key : Data(repeating: 0x43, count: 32))
                }, add: { _ in errSecDuplicateItem })
                XCTAssertTrue(matching)
            } catch { XCTAssertFalse(matching) }
            XCTAssertEqual(reads, 2)
        }
        XCTAssertThrowsError(try MessageArchiveKeychain.install(vaultID: UUID(), key: Data(), lookup: { _ in XCTFail("No invalid read"); return (errSecSuccess, key) },
            add: { _ in XCTFail("No invalid write"); return errSecSuccess }))
    }
    func testExistingKeyUsesProtectedSeparateNonsynchronizingItemWithoutMutation() throws {
        let key = Data(repeating: 7, count: 32)
        let value = try MessageArchiveKeychain.open(vaultID: UUID(), allowCreation: true, lookup: { query in
            XCTAssertEqual(query[kSecAttrService as String] as? String, "org.makosh.message-archive")
            XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            return (errSecSuccess, key)
        }, add: { _ in XCTFail("Existing key must not be replaced"); return errSecSuccess },
        random: { XCTFail("Existing key must not generate a replacement"); return Data() })
        XCTAssertEqual(value, key)
    }
    func testMissingOrLockedExistingVaultNeverCreatesReplacement() {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed] {
            XCTAssertThrowsError(try MessageArchiveKeychain.open(vaultID: UUID(), allowCreation: false,
                lookup: { _ in (status, nil) }, add: { _ in XCTFail("No replacement"); return errSecSuccess },
                random: { XCTFail("No replacement"); return Data() }))
        }
    }
    func testNewMacLoginKeychainKeyAndDuplicateRecoverExistingKey() throws {
        let existing = Data(repeating: 8, count: 32), generated = Data(repeating: 9, count: 32)
        var reads = 0
        let value = try MessageArchiveKeychain.open(vaultID: UUID(), allowCreation: true, lookup: { _ in
            reads += 1
            return reads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, existing)
        }, add: { item in
            XCTAssertNil(item[kSecAttrAccessible as String])
            XCTAssertEqual(item[kSecValueData as String] as? Data, generated)
            return errSecDuplicateItem
        }, random: { generated })
        XCTAssertEqual(value, existing)
    }
    func testInvalidKeyAndUnavailableSystemDoNotFallBackToFiles() {
        for size in [0, 31, 33] {
            XCTAssertThrowsError(try MessageArchiveKeychain.open(vaultID: UUID(), allowCreation: true,
                lookup: { _ in (errSecSuccess, Data(repeating: 1, count: size)) },
                add: { _ in XCTFail("No write"); return errSecSuccess }, random: { Data() }))
        }
        XCTAssertThrowsError(try MessageArchiveKeychain.open(vaultID: UUID(), allowCreation: true,
            lookup: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecInteractionNotAllowed },
            random: { Data(repeating: 1, count: 32) }))
    }
}

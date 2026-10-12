import XCTest
import Security
@testable import MakoshCore

final class MessageArchiveKeychainTests: XCTestCase {
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

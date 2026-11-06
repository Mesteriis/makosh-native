import Foundation
import Security
import XCTest
@testable import MakoshFiles

/// An in-memory Keychain: the tests never touch the login Keychain.
final class MemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: Data] = [:]
    var access: FileStorageKeychainAccess {
        FileStorageKeychainAccess(
            read: { id in self.lock.withLock { self.items[id].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) } },
            write: { id, data in
                self.lock.withLock { self.items[id] = data }
                return errSecSuccess
            },
            remove: { id in self.lock.withLock { self.items.removeValue(forKey: id) == nil ? errSecItemNotFound : errSecSuccess } })
    }
    var count: Int { lock.withLock { items.count } }
}

final class FileStorageTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let keychain = MemoryKeychain()
    private var vault: FileStorageTokenVault!
    private var registry: FileStorageRegistry!

    override func setUp() {
        super.setUp()
        suite = "makosh.files.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        vault = FileStorageTokenVault(access: keychain.access)
        registry = FileStorageRegistry(defaults: defaults, vault: vault)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    private func paperless(_ name: String = "Paperless", _ url: String = "https://doc.example") -> PaperlessConnection {
        PaperlessConnection(name: name, baseURL: URL(string: url)!)
    }

    func testValidationRejectsHTTPCredentialsAndTrailingSlash() throws {
        XCTAssertThrowsError(try paperless("P", "http://doc.example").validated())
        XCTAssertThrowsError(try paperless("P", "https://u:p@doc.example").validated())
        XCTAssertThrowsError(try paperless("P", "https://doc.example/?x=1").validated())
        XCTAssertThrowsError(try paperless("", "https://doc.example").validated())
        XCTAssertThrowsError(try paperless(String(repeating: "x", count: 81), "https://doc.example").validated())
        let trimmed = try paperless(" P ", "https://doc.example/").validated()
        XCTAssertEqual(trimmed.name, "P")
        XCTAssertEqual(trimmed.baseURL.absoluteString, "https://doc.example")
        XCTAssertEqual(
            try paperless("S", "https://doc.example/paperless/").validated().baseURL.absoluteString, "https://doc.example/paperless")
        XCTAssertNoThrow(try paperless("L", "http://127.0.0.1:8000").validated())
        XCTAssertNoThrow(try paperless("L", "http://localhost:8000").validated())
    }

    func testRegistryRoundTripsWithoutTokenInDefaults() async throws {
        let connection = paperless()
        try await registry.save(.paperless(connection), token: "secret-token")
        XCTAssertEqual(registry.connections(), [.paperless(connection)])
        let stored = try XCTUnwrap(defaults.data(forKey: FileStorageRegistry.key))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("secret-token"))
        let token = try await vault.load(connectionID: connection.id)
        XCTAssertEqual(token, "secret-token")
        let reopened = FileStorageRegistry(defaults: defaults, vault: vault)
        XCTAssertEqual(reopened.connections(), [.paperless(connection)])
    }

    func testSaveWithNilTokenKeepsExistingTokenAndReplacesConnection() async throws {
        var connection = paperless()
        try await registry.save(.paperless(connection), token: "first")
        connection.name = "Renamed"
        try await registry.save(.paperless(connection), token: nil)
        XCTAssertEqual(registry.connections().map(\.name), ["Renamed"])
        let token = try await vault.load(connectionID: connection.id)
        XCTAssertEqual(token, "first")
        try await registry.save(.paperless(connection), token: "second")
        let replaced = try await vault.load(connectionID: connection.id)
        XCTAssertEqual(replaced, "second")
    }

    func testRemoveDeletesConnectionAndToken() async throws {
        let connection = paperless()
        try await registry.save(.paperless(connection), token: "t")
        try await registry.remove(connection.id)
        XCTAssertEqual(registry.connections(), [])
        let token = try await vault.load(connectionID: connection.id)
        XCTAssertNil(token)
        XCTAssertEqual(keychain.count, 0)
    }

    func testSaveRejectsInvalidConnectionWithoutTouchingTokens() async throws {
        let bad = paperless("P", "http://doc.example")
        do {
            try await registry.save(.paperless(bad), token: "t")
            XCTFail("invalid connection must not save")
        } catch let error as FilesFailure { XCTAssertEqual(error, .invalidConnection) }
        XCTAssertEqual(registry.connections(), [])
        XCTAssertEqual(keychain.count, 0)
    }

    func testCorruptDefaultsYieldEmptyList() {
        defaults.set(Data("garbage".utf8), forKey: FileStorageRegistry.key)
        XCTAssertEqual(registry.connections(), [])
    }
}

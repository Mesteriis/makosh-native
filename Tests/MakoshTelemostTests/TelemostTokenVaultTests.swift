import XCTest
import Security
@testable import MakoshTelemost

final class TelemostTestKeychain: @unchecked Sendable {
    let lock = NSLock()
    var data: Data?
    var failWrites = false
    var access: TelemostKeychainAccess {
        .init(read: { _ in self.lock.withLock { (self.data == nil ? errSecItemNotFound : errSecSuccess, self.data) } },
              write: { _, data in self.lock.withLock { if self.failWrites { return errSecAuthFailed }; self.data = data; return errSecSuccess } },
              remove: { _ in self.lock.withLock { self.data = nil; return errSecSuccess } })
    }
}
@MainActor
final class TelemostTokenVaultTests: XCTestCase {
    func testVaultFailurePreservesPreviousToken() async throws {
        let backend = TelemostTestKeychain(), vault = TelemostTokenVault(access: backend.access)
        let old = TelemostToken(accessToken: "old-synthetic", refreshToken: nil, expiresAt: Date(timeIntervalSince1970: 9999),
            capabilities: [.read], principal: .init(userID: "synthetic-user", clientID: String(repeating: "a", count: 32), login: "Synthetic"))
        try await vault.save(old, accountID: telemostTestAccountID)
        backend.lock.withLock { backend.failWrites = true }
        var new = old; new.accessToken = "new-synthetic"
        do { try await vault.save(new, accountID: telemostTestAccountID); XCTFail("write failure hidden") } catch {}
        let retained = try await vault.load(accountID: telemostTestAccountID)
        XCTAssertEqual(retained?.accessToken, "old-synthetic")
    }
    func testKeychainFailureIsNotMissingToken() async throws {
        let access = TelemostKeychainAccess(read: { _ in (errSecAuthFailed, nil) }, write: { _, _ in errSecAuthFailed }, remove: { _ in errSecAuthFailed })
        let vault = TelemostTokenVault(access: access)
        do { _ = try await vault.load(accountID: telemostTestAccountID); XCTFail("error treated as missing") }
        catch { XCTAssertEqual(error as? TelemostFailure, .keyUnavailable) }
    }
}

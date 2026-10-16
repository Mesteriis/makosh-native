import XCTest
import Security
@testable import MakoshTeams

final class TeamsFakeKeychain: TeamsKeychainAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    private var rejectWrites = false
    func copy(account: String) -> (OSStatus, Data?) { lock.withLock { data[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) } }
    func update(account: String, data value: Data) -> OSStatus {
        lock.withLock {
            if rejectWrites { return errSecAuthFailed }
            guard data[account] != nil else { return errSecItemNotFound }
            data[account] = value; return errSecSuccess
        }
    }
    func add(account: String, data value: Data) -> OSStatus {
        lock.withLock {
            if rejectWrites { return errSecAuthFailed }
            guard data[account] == nil else { return errSecDuplicateItem }
            data[account] = value; return errSecSuccess
        }
    }
    func setRejectWrites(_ value: Bool) { lock.withLock { rejectWrites = value } }
}

@MainActor
final class TeamsTokenVaultTests: XCTestCase {
    func testRevokedAuthorizationPermitPreventsCredentialWrite() async throws {
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        let permit = TeamsAuthorizationPermit()
        permit.cancel()
        let bundle = TeamsTokenBundle(accessToken: "late", refreshToken: "late-refresh", idToken: nil,
            expiresAt: Date().addingTimeInterval(3600), grantedScopes: [], expectedNonce: nil)
        do { try await vault.save(bundle, accountID: teamsTestContext.accountID, permit: permit); XCTFail("Revoked write admitted") }
        catch is CancellationError {}
        let stored = try await vault.load(accountID: teamsTestContext.accountID)
        XCTAssertNil(stored)
    }
    // An unsuccessful checked Keychain update must not delete/reset the previous session.
    func testVaultFailurePreservesExistingCredential() async throws {
        let api = TeamsFakeKeychain()
        let vault = TeamsTokenVault(api: api)
        let original = TeamsTokenBundle(accessToken: "original", refreshToken: "refresh", idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 1_800_003_600), grantedScopes: ["Chat.Read"], expectedNonce: nil)
        try await vault.save(original, accountID: teamsTestContext.accountID)
        api.setRejectWrites(true)
        let replacement = TeamsTokenBundle(accessToken: "replacement", refreshToken: "rotated", idToken: nil,
            expiresAt: original.expiresAt, grantedScopes: original.grantedScopes, expectedNonce: nil)
        do { try await vault.save(replacement, accountID: teamsTestContext.accountID); XCTFail("Unchecked save") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .credentialStorage) }
        let loaded = try await vault.load(accountID: teamsTestContext.accountID)
        XCTAssertEqual(loaded, original)
        let unrelated = try await vault.load(accountID: UUID())
        XCTAssertNil(unrelated)
    }
}

import Foundation
import XCTest

@testable import MakoshGoogle

final class GoogleGrantVaultTests: XCTestCase {
    func testGrantIndexListsSavedGrants() async throws {
        let vault = GoogleGrantVault(access: .memory())
        let first = GoogleGrant(subject: "10001", email: "me@gmail.test", scopes: ["openid"], refreshToken: "rt-1")
        let second = GoogleGrant(subject: "10002", email: "work@gmail.test", scopes: ["openid"], refreshToken: "rt-2")
        try await vault.saveGrant(first)
        try await vault.saveGrant(second)
        try await vault.saveGrant(first)
        let listed = try await vault.grants()
        XCTAssertEqual(listed.map(\.subject), ["10001", "10002"], "each account once, in sign-in order")
        try await vault.removeGrant(subject: "10001")
        let remaining = try await vault.grants()
        XCTAssertEqual(remaining.map(\.subject), ["10002"])
        let gone = try await vault.grant(subject: "10001")
        XCTAssertNil(gone)
        XCTAssertFalse(String(describing: first).contains("rt-1"))
    }
}

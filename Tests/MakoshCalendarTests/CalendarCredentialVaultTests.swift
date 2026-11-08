import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarCredentialVaultTests: XCTestCase {
    func testVaultRoundTripsAndKeepsSecretsOutOfDescriptions() async throws {
        let vault = CalendarCredentialVault(access: .memory())
        let grant = GoogleGrant(subject: "10001", email: "me@gmail.test", scopes: ["openid"], refreshToken: "refresh-secret")
        try await vault.saveGrant(grant)
        let read = try await vault.grant(subject: "10001")
        XCTAssertEqual(read, grant)
        XCTAssertFalse(String(describing: grant).contains("refresh-secret"))
        XCTAssertFalse(String(reflecting: grant).contains("refresh-secret"))
        try await vault.removeGrant(subject: "10001")
        let gone = try await vault.grant(subject: "10001")
        XCTAssertNil(gone)

        let account = UUID()
        try await vault.savePassword("app-password", accountID: account)
        let password = try await vault.password(accountID: account)
        XCTAssertEqual(password, "app-password")
        try await vault.removePassword(accountID: account)
        let removed = try await vault.password(accountID: account)
        XCTAssertNil(removed)
    }

    func testRejectsControlCharactersInPassword() async {
        let vault = CalendarCredentialVault(access: .memory())
        do {
            try await vault.savePassword("bad\npassword", accountID: UUID())
            XCTFail("control characters must be refused")
        } catch { XCTAssertEqual(error as? CalendarFailure, .invalidInput("password")) }
    }
}

import Foundation
import MakoshGoogle
import XCTest

@testable import MakoshOSINT

final class OSINTCredentialVaultTests: XCTestCase {
    func testRoundTripsEachKind() async throws {
        let vault = OSINTCredentialVault(access: .memory())
        try await vault.saveSSHPassword("ssh-secret-1")
        try await vault.saveServicePassword("service-secret-2")
        try await vault.saveEnvSecret(name: "AUTH_SECRET", "env-secret-3")
        try await vault.saveKey(name: "HIBP_API_KEY", "key-secret-4")
        let ssh = try await vault.sshPassword()
        let service = try await vault.servicePassword()
        let env = try await vault.envSecret(name: "AUTH_SECRET")
        let key = try await vault.key(name: "HIBP_API_KEY")
        XCTAssertEqual(ssh, "ssh-secret-1")
        XCTAssertEqual(service, "service-secret-2")
        XCTAssertEqual(env, "env-secret-3")
        XCTAssertEqual(key, "key-secret-4")
        let missing = try await vault.envSecret(name: "NEO4J_PASSWORD")
        XCTAssertNil(missing)
        try await vault.removeKey(name: "HIBP_API_KEY")
        let removed = try await vault.key(name: "HIBP_API_KEY")
        XCTAssertNil(removed)
        try await vault.removeKey(name: "HIBP_API_KEY")  // removing twice is not an error
        XCTAssertEqual(OSINTCredentialVault.service, "org.makosh.osint.v1")
    }

    func testHMACIsStableAndKeyed() async throws {
        let vault = OSINTCredentialVault(access: .memory())
        try await vault.ensureHMACKey()
        let a = try await vault.hmac("Anna@Example.test")
        let b = try await vault.hmac(" anna@example.test ")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "case and surrounding whitespace do not change the digest")
        XCTAssertEqual(a?.count, 64, "hex of HMAC-SHA256")
        try await vault.ensureHMACKey()
        let again = try await vault.hmac("anna@example.test")
        XCTAssertEqual(again, a, "ensureHMACKey keeps an existing key")
        let other = OSINTCredentialVault(access: .memory())
        try await other.ensureHMACKey()
        let foreign = try await other.hmac("anna@example.test")
        XCTAssertNotEqual(foreign, a, "another key gives another digest")
        XCTAssertNotEqual(a, "anna@example.test")
    }

    func testHMACWithoutKeyIsNil() async throws {
        let vault = OSINTCredentialVault(access: .memory())
        let digest = try await vault.hmac("+79990000000")
        XCTAssertNil(digest)
    }

    func testRejectsControlCharacters() async throws {
        let vault = OSINTCredentialVault(access: .memory())
        for bad in ["", "line\nbreak", "tab\tbed"] {
            do {
                try await vault.saveSSHPassword(bad)
                XCTFail("accepted \(bad.debugDescription)")
            } catch { XCTAssertEqual(error as? OSINTFailure, .storage("secret"), "\(error)") }
        }
        do {
            try await vault.saveKey(name: "HIBP_API_KEY", String(repeating: "x", count: 16 * 1024 + 1))
            XCTFail("accepted an oversized secret")
        } catch { XCTAssertEqual(error as? OSINTFailure, .storage("secret"), "\(error)") }
        let none = try await vault.sshPassword()
        XCTAssertNil(none)
    }

    func testRemoveAllClearsEverything() async throws {
        let vault = OSINTCredentialVault(access: .memory())
        try await vault.saveSSHPassword("a")
        try await vault.saveServicePassword("b")
        try await vault.saveEnvSecret(name: "NEO4J_PASSWORD", "c")
        try await vault.saveKey(name: "WHOXY_API_KEY", "d")
        try await vault.ensureHMACKey()
        try await vault.removeAll()
        let ssh = try await vault.sshPassword()
        let service = try await vault.servicePassword()
        let env = try await vault.envSecret(name: "NEO4J_PASSWORD")
        let key = try await vault.key(name: "WHOXY_API_KEY")
        let digest = try await vault.hmac("x")
        XCTAssertNil(ssh)
        XCTAssertNil(service)
        XCTAssertNil(env)
        XCTAssertNil(key)
        XCTAssertNil(digest)
    }
}

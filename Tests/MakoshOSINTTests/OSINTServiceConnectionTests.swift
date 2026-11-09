import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

final class OSINTServiceConnectionTests: XCTestCase {
    private var harnesses: [OSINTServiceHarness] = []

    override func tearDown() async throws {
        for harness in harnesses { await harness.stop() }
        harnesses = []
    }

    private func harness(
        state: OSINTScriptedServerState = OSINTScriptedServerState(), installed: Bool = false
    ) async throws -> OSINTServiceHarness {
        let harness = try await OSINTServiceHarness(database: try osintDatabase(), state: state, installed: installed)
        harnesses.append(harness)
        return harness
    }

    func testSaveConnectionStoresPasswordInVaultOnly() async throws {
        let h = try await harness()
        try await h.service.saveConnection(host: "10.34.10.64", port: 22, login: "makosh", password: "secret-ssh")
        let settings = try await h.service.settings()
        XCTAssertEqual(settings.host, "10.34.10.64")
        XCTAssertEqual(settings.login, "makosh")
        let rows = try h.db.execute("SELECT data::text FROM persons_osint_settings")
        XCTAssertFalse(rows.joined().joined().contains("secret-ssh"))
        let stored = try await h.vault.sshPassword()
        XCTAssertEqual(stored, "secret-ssh")
        try await h.service.saveConnection(host: "10.34.10.64", port: 22, login: "makosh", password: nil)
        let kept = try await h.vault.sshPassword()
        XCTAssertEqual(kept, "secret-ssh", "nil keeps the stored password")
    }

    func testTestConnectionSavesAcceptedFingerprint() async throws {
        let h = try await harness()
        try await h.configure()
        let report = try await h.service.testConnection { _ in true }
        XCTAssertEqual(report.fingerprint, h.endpoint.fingerprint)
        XCTAssertTrue(report.trusted)
        XCTAssertEqual(report.dockerPresent, true)
        XCTAssertNil(report.checkedOutSHA, "nothing is checked out yet")
        XCTAssertEqual(report.healthy, false)
        let settings = try await h.service.settings()
        XCTAssertEqual(settings.hostKeyFingerprint, h.endpoint.fingerprint)
        let again = try await h.service.testConnection { _ in
            XCTFail("a trusted key is not asked about")
            return false
        }
        XCTAssertTrue(again.trusted)
    }

    func testTestConnectionWithDeclinedKeyLeavesNothing() async throws {
        let h = try await harness()
        try await h.configure()
        do {
            _ = try await h.service.testConnection { _ in false }
            XCTFail("declined")
        } catch { XCTAssertEqual(error as? OSINTFailure, .hostKeyMismatch, "\(error)") }
        let settings = try await h.service.settings()
        XCTAssertNil(settings.hostKeyFingerprint)
        let snapshotConnected = await h.service.isConnected
        XCTAssertFalse(snapshotConnected)
    }

    func testChangedHostResetsFingerprint() async throws {
        let h = try await harness()
        try await h.configure()
        try await h.trust()
        try await h.service.saveConnection(host: "10.34.10.65", port: h.endpoint.port, login: "makosh", password: nil)
        let settings = try await h.service.settings()
        XCTAssertNil(settings.hostKeyFingerprint, "another host means another key")
        let connected = await h.service.isConnected
        XCTAssertFalse(connected)
        try await h.service.saveConnection(host: "10.34.10.65", port: 2222, login: "makosh", password: nil)
        let samePort = try await h.service.settings()
        XCTAssertEqual(samePort.port, 2222)
    }

    func testInstallRequiresTrustedKeyAndEnabled() async throws {
        let h = try await harness()
        try await h.configure(enabled: false)
        do {
            _ = try await h.service.install { _ in }
            XCTFail("disabled")
        } catch { XCTAssertEqual(error as? OSINTFailure, .disabled, "\(error)") }
        var settings = try await h.service.settings()
        settings.enabled = true
        try await h.service.saveSettings(settings)
        do {
            _ = try await h.service.install { _ in }
            XCTFail("untrusted key")
        } catch { XCTAssertEqual(error as? OSINTFailure, .hostKeyMismatch, "\(error)") }
        XCTAssertTrue(h.state.commands.isEmpty, "no command ran before trust")
    }

    func testInstallRecordsVersion() async throws {
        let h = try await harness()
        let install = try await h.installed()
        XCTAssertEqual(install.state, .completed)
        let settings = try await h.service.settings()
        XCTAssertEqual(settings.installedSHA, FlowsintPin.current.sha)
        XCTAssertEqual(settings.installedTag, "v1.2.13")
        let snapshotInstalls = try await h.store.installs()
        XCTAssertEqual(snapshotInstalls.count, 1)
        let report = try await h.service.testConnection { _ in true }
        XCTAssertEqual(report.checkedOutSHA, FlowsintPin.current.sha)
        XCTAssertEqual(report.healthy, true)
    }

    func testOpenMarksSentUnknownAndEnsuresHMAC() async throws {
        let h = try await harness()
        let settings = try await h.service.settings()
        XCTAssertTrue(settings.hmacKeyAvailable)
        let digest = try await h.vault.hmac("anna@example.test")
        XCTAssertNotNil(digest, "open created the journal key")
        var attempt = OSINTAttempt(kind: .launch, payload: OSINTAttemptPayload(enricher: .emailToGravatar))
        try await h.store.saveAttempt(attempt)
        attempt.state = .sent
        try await h.store.saveAttempt(attempt)
        let api = h.api
        let second = OSINTService(
            persons: h.persons, store: h.store, vault: h.vault, sessionFactory: { _, _ in fatalError("unused") },
            apiFactory: { _, _, _ in api })
        try await second.open()
        let reread = try await h.store.attempt(id: attempt.id)
        XCTAssertEqual(reread?.state, .unknown)
        await second.close()
    }

    func testSetServicePasswordVerifiesLogin() async throws {
        let h = try await harness()
        try await h.installed()
        let current = try await h.service.servicePassword()
        XCTAssertNotNil(current)
        do {
            try await h.service.setServicePassword("not-the-one")
            XCTFail("the server has another password")
        } catch { XCTAssertEqual(error as? OSINTFailure, .serviceAuthFailed, "\(error)") }
        let saved = try await h.vault.servicePassword()
        XCTAssertEqual(saved, "not-the-one", "the typed password is stored even when the check fails")
        try await h.service.setServicePassword(current!)
        let restored = try await h.vault.servicePassword()
        XCTAssertEqual(restored, current)
    }

    func testRegisterNewServiceUserChangesEmail() async throws {
        let h = try await harness()
        try await h.installed()
        let before = try await h.service.settings()
        try await h.service.registerNewServiceUser()
        let after = try await h.service.settings()
        XCTAssertNotEqual(after.serviceEmail, before.serviceEmail)
        XCTAssertTrue(after.serviceEmail.hasPrefix("makosh-osint+"), after.serviceEmail)
        XCTAssertTrue(after.serviceEmail.hasSuffix("@sh-inc.dev"), after.serviceEmail)
        let users = await h.api.users
        XCTAssertEqual(users.count, 2)
        let password = try await h.vault.servicePassword()
        XCTAssertEqual(password?.count, 32)
    }
}

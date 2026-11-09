import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshOSINT

/// Everything an `OSINTService` test needs: a dossier store and the module store on one generated
/// schema, a Keychain in memory, a scripted SSH server standing in for LXC 164 and a synthetic flowsint.
final class OSINTServiceHarness {
    let db: OSINTTestDatabase
    let persons: PersonStore
    let store: OSINTStore
    let vault: OSINTCredentialVault
    let state: OSINTScriptedServerState
    let server: OSINTSyntheticSSHServer
    let api: FlowsintSynthetic
    let endpoint: (host: String, port: Int, fingerprint: String)
    let service: OSINTService
    static let password = "pw-1"

    init(
        testCase: XCTestCase, state: OSINTScriptedServerState = OSINTScriptedServerState(), findings: [FlowsintSynthetic.Finding] = [],
        installed: Bool = false, scanTimeout: Duration = .seconds(10), now: @escaping @Sendable () -> Date = Date.init
    ) async throws {
        db = try testCase.osintDatabase()
        persons = try db.persons()
        store = OSINTStore(connectionString: db.connectionString, schema: db.schema, now: now)
        vault = OSINTCredentialVault(access: .memory())
        self.state = state
        let api = FlowsintSynthetic(findings: findings, installed: installed)
        self.api = api
        state.onUp = { Task { await api.setInstalled(true) } }
        server = OSINTSyntheticSSHServer(login: "makosh", password: Self.password, script: state.script)
        endpoint = try await server.start()
        service = OSINTService(
            persons: persons, store: store, vault: vault,
            sessionFactory: { settings, password in
                OSINTSSHSession(
                    host: settings.host, port: settings.port, login: settings.login, password: password,
                    expectedFingerprint: settings.hostKeyFingerprint)
            },
            apiFactory: { _, _, _ in api }, scanTimeout: scanTimeout, pollInterval: .milliseconds(20), healthPoll: .milliseconds(20),
            now: now)
        try await service.open()
    }

    /// Host, port, login and password of the scripted server saved into the service.
    func configure(enabled: Bool = true) async throws {
        try await service.saveConnection(host: endpoint.host, port: endpoint.port, login: "makosh", password: Self.password)
        var settings = try await service.settings()
        settings.enabled = enabled
        try await service.saveSettings(settings)
    }

    /// Trusts the server's key the way the user does from the settings.
    @discardableResult
    func trust() async throws -> OSINTConnectionReport {
        try await service.testConnection { _ in true }
    }

    /// A trusted, installed server: what every enrichment test starts from.
    @discardableResult
    func installed() async throws -> OSINTInstall {
        try await configure()
        try await trust()
        let install = try await service.install { _ in }
        XCTAssertEqual(install.state, .completed, "\(install.steps)")
        return install
    }

    func stop() async {
        await service.close()
        await server.stop()
    }
}

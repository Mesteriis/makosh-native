import Foundation
import MakoshGoogle
import XCTest

@testable import MakoshOSINT

final class FlowsintInstallerTests: XCTestCase {
    /// Everything one installer run needs: a scripted SSH server, a synthetic flowsint, a store, a Keychain in memory.
    struct Harness {
        let state: OSINTScriptedServerState
        let server: OSINTSyntheticSSHServer
        let api: FlowsintSynthetic
        let session: OSINTSSHSession
        let vault: OSINTCredentialVault
        let store: OSINTStore
        let db: OSINTTestDatabase

        func installer(healthTimeout: Duration = .seconds(10)) -> FlowsintInstaller {
            FlowsintInstaller(
                session: session, api: api, vault: vault, store: store, healthTimeout: healthTimeout, healthPoll: .milliseconds(50))
        }

        func run() async -> OSINTInstall { await installer().run { _ in } }

        func stop() async {
            await session.close()
            await server.stop()
        }
    }

    private var harnesses: [Harness] = []

    override func tearDown() async throws {
        for harness in harnesses { await harness.stop() }
        harnesses = []
    }

    private func harness(state: OSINTScriptedServerState = OSINTScriptedServerState(), installed: Bool = false) async throws -> Harness {
        let api = FlowsintSynthetic(installed: installed)
        state.onUp = { Task { await api.setInstalled(true) } }
        let server = OSINTSyntheticSSHServer(login: "makosh", password: "pw-1", script: state.script)
        let endpoint = try await server.start()
        let session = OSINTSSHSession(
            host: endpoint.host, port: endpoint.port, login: "makosh", password: { "pw-1" }, expectedFingerprint: nil)
        _ = try await session.connect { _ in true }
        let db = try osintDatabase()
        let store = try await osintStore(db)
        let harness = Harness(
            state: state, server: server, api: api, session: session, vault: OSINTCredentialVault(access: .memory()), store: store, db: db)
        harnesses.append(harness)
        return harness
    }

    private func states(_ install: OSINTInstall) -> [OSINTInstallStepKind: OSINTInstallStepState] {
        Dictionary(uniqueKeysWithValues: install.steps.map { ($0.kind, $0.state) })
    }

    func testFreshServerRunsEverySteps() async throws {
        let h = try await harness()
        let progress = Box<Int>(0)
        let install = await h.installer().run { _ in progress.value += 1 }
        XCTAssertEqual(install.state, .completed, "\(install.steps)")
        let states = states(install)
        XCTAssertEqual(states[.connect], .skipped)
        for kind in OSINTInstallStepKind.allCases where kind != .connect { XCTAssertEqual(states[kind], .done, "\(kind)") }
        XCTAssertGreaterThanOrEqual(progress.value, OSINTInstallStepKind.allCases.count)
        XCTAssertTrue(
            h.state.commands.contains {
                $0.hasPrefix("git clone --branch v1.2.13 --depth 1 https://github.com/reconurge/flowsint /opt/flowsint")
            })
        XCTAssertEqual(h.state.envWrites, 1)
        XCTAssertTrue(h.state.lastEnv?.contains("FLOWSINT_VERSION=v1.2.13") == true)
        XCTAssertTrue(h.state.lastEnv?.contains("MASTER_VAULT_KEY_V1=base64:") == true)
        XCTAssertTrue(h.state.overrideText?.contains("flowsint-api:\(FlowsintPin.current.sha)") == true)
        XCTAssertTrue(h.state.overrideText?.contains("context: ./flowsint-app") == true)
        XCTAssertEqual(h.state.builtSHA, FlowsintPin.current.sha)
        XCTAssertTrue(h.state.up)
        let users = await h.api.users
        XCTAssertEqual(users, ["makosh-osint@sh-inc.dev"])
        let settings = try await h.store.settings()
        XCTAssertNotNil(settings.investigationID)
        XCTAssertEqual(settings.installedTag, "v1.2.13")
        XCTAssertEqual(settings.installedSHA, FlowsintPin.current.sha)
        XCTAssertNotNil(settings.installedAt)
        XCTAssertEqual(Set(settings.imageIDs.keys), ["flowsint-api", "flowsint-app"])
        XCTAssertTrue(settings.envBackupAvailable)
        let auth = try await h.vault.envSecret(name: "AUTH_SECRET")
        XCTAssertEqual(auth?.count, 64, "32 random bytes as hex")
        let service = try await h.vault.servicePassword()
        XCTAssertEqual(service?.count, 32)
        let installs = try await h.store.installs()
        XCTAssertEqual(installs.count, 1)
        XCTAssertEqual(installs.first?.state, .completed)
    }

    func testRerunOnInstalledServerSkipsEverything() async throws {
        let h = try await harness()
        let first = await h.run()
        XCTAssertEqual(first.state, .completed)
        let registrations = await h.api.users.count
        h.state.commands = []
        let second = await h.run()
        XCTAssertEqual(second.state, .completed, "\(second.steps)")
        let states = states(second)
        // The Docker check and the version record run every time; everything that changes the server is skipped.
        for kind in OSINTInstallStepKind.allCases where kind != .record && kind != .docker {
            XCTAssertEqual(states[kind], .skipped, "\(kind)")
        }
        XCTAssertEqual(states[.docker], .done)
        XCTAssertEqual(states[.record], .done)
        XCTAssertEqual(h.state.envWrites, 1, ".env is never written twice")
        XCTAssertFalse(h.state.commands.contains { $0.hasPrefix("git clone") || $0.hasSuffix(" build") || $0.contains(" up -d") })
        let users = await h.api.users.count
        XCTAssertEqual(users, registrations, "no second service user")
        let installs = try await h.store.installs()
        XCTAssertEqual(installs.count, 2)
    }

    func testMissingDockerStopsEarly() async throws {
        let h = try await harness(state: OSINTScriptedServerState(hasDocker: false))
        let install = await h.run()
        XCTAssertEqual(install.state, .failed)
        let docker = install.steps.first { $0.kind == .docker }
        XCTAssertEqual(docker?.state, .failed)
        XCTAssertEqual(docker?.failure, .dockerMissing)
        XCTAssertEqual(states(install)[.checkout], .pending)
        XCTAssertFalse(h.state.commands.contains { $0.hasPrefix("git clone") })
    }

    func testMissingGitIsGitMissing() async throws {
        let h = try await harness(state: OSINTScriptedServerState(hasGit: false))
        let install = await h.run()
        XCTAssertEqual(install.state, .failed)
        XCTAssertEqual(install.steps.first { $0.kind == .docker }?.failure, .gitMissing)
    }

    func testWrongShaAfterCheckoutFails() async throws {
        let h = try await harness(state: OSINTScriptedServerState(cloneSHA: String(repeating: "0", count: 40)))
        let install = await h.run()
        XCTAssertEqual(install.state, .failed)
        XCTAssertEqual(install.steps.first { $0.kind == .checkout }?.failure, .installFailed(stage: "checkout"))
        XCTAssertEqual(h.state.envWrites, 0)
    }

    func testEnvStepLeavesNoSecretInSteps() async throws {
        let h = try await harness()
        let install = await h.run()
        XCTAssertEqual(install.state, .completed)
        let json = String(decoding: try JSONEncoder().encode(install), as: UTF8.self)
        for name in ["AUTH_SECRET", "MASTER_VAULT_KEY_V1", "NEO4J_PASSWORD", "POSTGRES_PASSWORD"] {
            let stored = try await h.vault.envSecret(name: name)
            let value = try XCTUnwrap(stored, name)
            XCTAssertFalse(json.contains(value), "\(name) leaked into the install journal")
            XCTAssertFalse(json.contains(value.replacingOccurrences(of: "base64:", with: "")))
        }
        let servicePassword = try await h.vault.servicePassword()
        let service = try XCTUnwrap(servicePassword)
        XCTAssertFalse(json.contains(service))
        let rows = try h.db.execute("SELECT data::text FROM persons_osint_installs")
        XCTAssertFalse(rows.joined().joined().contains(service))
    }

    func testExistingEnvWithoutKeychainMarksBackupUnavailable() async throws {
        let h = try await harness(state: OSINTScriptedServerState(hasEnv: true))
        let install = await h.run()
        XCTAssertEqual(install.state, .completed, "\(install.steps)")
        XCTAssertEqual(states(install)[.env], .skipped)
        XCTAssertEqual(h.state.envWrites, 0)
        let settings = try await h.store.settings()
        XCTAssertFalse(settings.envBackupAvailable)
        let auth = try await h.vault.envSecret(name: "AUTH_SECRET")
        XCTAssertNil(auth, "nothing is invented for a foreign .env")
    }

    func testHealthTimeoutFailsUp() async throws {
        let state = OSINTScriptedServerState()
        let h = try await harness(state: state)
        state.onUp = nil  // the stack never becomes healthy
        let install = await h.installer(healthTimeout: .milliseconds(300)).run { _ in }
        XCTAssertEqual(install.state, .failed)
        XCTAssertEqual(install.steps.first { $0.kind == .up }?.failure, .healthTimeout)
        XCTAssertEqual(states(install)[.register], .pending)
    }

    func testExistingUserWithWrongPasswordIsServiceAuthFailed() async throws {
        let h = try await harness()
        _ = try await h.api.register(email: "makosh-osint@sh-inc.dev", password: "someone-elses")
        let install = await h.run()
        XCTAssertEqual(install.state, .failed)
        XCTAssertEqual(install.steps.first { $0.kind == .register }?.failure, .serviceAuthFailed)
        let settings = try await h.store.settings()
        XCTAssertNil(settings.installedSHA, "record did not run")
    }
}

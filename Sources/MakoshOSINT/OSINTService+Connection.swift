import Foundation

extension OSINTService {
    /// The live connection, opened on demand. Without a trusted host key nothing connects: the user
    /// checks the connection first. Without an installation only the installer may proceed.
    func ensureConnected(requireInstalled: Bool = true) async throws -> Connection {
        let settings = try await store.settings()
        guard settings.enabled else { throw OSINTFailure.disabled }
        guard settings.hostKeyFingerprint != nil else { throw OSINTFailure.hostKeyMismatch }
        if requireInstalled, settings.installedSHA == nil { throw OSINTFailure.notInstalled }
        if let connection, await connection.session.isConnected { return connection }
        return try await connect(settings) { _ in false }
    }

    private func connect(_ settings: OSINTSettings, onUnknownHostKey: @escaping @Sendable (String) async -> Bool) async throws -> Connection
    {
        await disconnect()
        let vault = self.vault
        let session = sessionFactory(settings) { try await vault.sshPassword() }
        _ = try await session.connect(onUnknownHostKey: onUnknownHostKey)
        let tunnel = try await session.openTunnel(toPort: 5173)
        let link = Connection(session: session, tunnel: tunnel, api: apiFactory(tunnel, settings, vault))
        connection = link
        return link
    }

    /// Connects (asking about an unknown key), remembers an accepted key and reports what the server has.
    public func testConnection(onUnknownHostKey: @escaping @Sendable (String) async -> Bool) async throws -> OSINTConnectionReport {
        var settings = try await store.settings()
        guard !settings.host.isEmpty, !settings.login.isEmpty else { throw OSINTFailure.invalidInput("connection") }
        let link = try await connect(settings, onUnknownHostKey: onUnknownHostKey)
        let fingerprint = await link.session.fingerprint ?? settings.hostKeyFingerprint ?? ""
        if settings.hostKeyFingerprint == nil {
            settings.hostKeyFingerprint = fingerprint
            try await store.saveSettings(settings)
        }
        var report = OSINTConnectionReport(fingerprint: fingerprint, trusted: true)
        if let docker = try? await link.session.exec("docker version --format '{{.Server.Version}}' && docker compose version --short") {
            report.dockerPresent = docker.status == 0
        }
        if let head = try? await link.session.exec("git -C \(FlowsintInstaller.root) rev-parse HEAD"), head.status == 0 {
            report.checkedOutSHA = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        report.healthy = (try? await link.api.health()) ?? false
        return report
    }

    /// Installs or updates flowsint to the pinned release; requires the module on and a trusted key.
    public func install(progress: @escaping @Sendable (OSINTInstall) -> Void) async throws -> OSINTInstall {
        guard !installing else { throw OSINTFailure.invalidInput("install in progress") }
        let link = try await ensureConnected(requireInstalled: false)
        installing = true
        defer { installing = false }
        let installer = FlowsintInstaller(
            session: link.session, api: link.api, vault: vault, store: store, pin: pin, now: now, healthTimeout: .seconds(300),
            healthPoll: healthPoll)
        return await installer.run(progress: progress)
    }
}

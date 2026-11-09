import Foundation
import MakoshCore

/// What a connection check learnt about the server, for the settings screen.
public struct OSINTConnectionReport: Equatable, Sendable {
    public var fingerprint: String
    public var trusted: Bool
    public var dockerPresent: Bool?
    public var checkedOutSHA: String?
    public var healthy: Bool?
    public init(fingerprint: String, trusted: Bool, dockerPresent: Bool? = nil, checkedOutSHA: String? = nil, healthy: Bool? = nil) {
        self.fingerprint = fingerprint
        self.trusted = trusted
        self.dockerPresent = dockerPresent
        self.checkedOutSHA = checkedOutSHA
        self.healthy = healthy
    }
}

/// The OSINT module's service: one SSH connection with a tunnel to flowsint, the installer, the
/// enrichment runner, the attempt journal and the reconciliation pass. Everything off the main actor;
/// the workspace model only reads snapshots and sends commands.
public actor OSINTService {
    public typealias SessionFactory = @Sendable (OSINTSettings, @escaping @Sendable () async throws -> String?) -> OSINTSSHSession
    public typealias APIFactory = @Sendable (OSINTTunnel, OSINTSettings, OSINTCredentialVault) -> any FlowsintAPI

    let persons: PersonStore
    let store: OSINTStore
    let vault: OSINTCredentialVault
    let sessionFactory: SessionFactory
    let apiFactory: APIFactory
    let pin: FlowsintPin
    let scanTimeout: Duration
    let pollInterval: Duration
    let healthPoll: Duration
    let now: @Sendable () -> Date

    struct Connection {
        var session: OSINTSSHSession
        var tunnel: OSINTTunnel
        var api: any FlowsintAPI
    }
    var connection: Connection?
    /// The connect in flight, shared by concurrent callers so one drop opens one session.
    var connecting: _Concurrency.Task<Connection, Error>?
    var installing = false
    var lastFailure: OSINTFailure?
    /// Inputs of queued runs: in memory only, never in a row.
    var pendingInputs: [UUID: [OSINTInput]] = [:]
    /// Names of the keys the server holds, as last read; values never leave the server.
    var serverKeyNames: Set<String> = []
    var runner: _Concurrency.Task<Void, Never>?
    var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        persons: PersonStore, store: OSINTStore, vault: OSINTCredentialVault, sessionFactory: @escaping SessionFactory,
        apiFactory: @escaping APIFactory, pin: FlowsintPin = .current, scanTimeout: Duration = .seconds(600),
        pollInterval: Duration = .seconds(3), healthPoll: Duration = .seconds(5), now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persons = persons
        self.store = store
        self.vault = vault
        self.sessionFactory = sessionFactory
        self.apiFactory = apiFactory
        self.pin = pin
        self.scanTimeout = scanTimeout
        self.pollInterval = pollInterval
        self.healthPoll = healthPoll
        self.now = now
    }

    /// The production factories: a password SSH session to the configured host and a REST client through the tunnel.
    public static func liveFactories() -> (SessionFactory, APIFactory) {
        let session: SessionFactory = { settings, password in
            OSINTSSHSession(
                host: settings.host, port: settings.port, login: settings.login, password: password,
                expectedFingerprint: settings.hostKeyFingerprint)
        }
        let api: APIFactory = { tunnel, settings, vault in
            FlowsintClient(baseURL: tunnel.baseURL) {
                guard let password = try await vault.servicePassword() else { return nil }
                return (settings.serviceEmail, password)
            }
        }
        return (session, api)
    }

    // MARK: Lifecycle

    public func open() async throws {
        try await store.open()
        try await store.markSentAsUnknownOnOpen()
        // A queued run's inputs lived only in memory: after a restart it cannot start.
        for var run in try await store.runs(open: true) where run.state == .queued && pendingInputs[run.id] == nil {
            run.state = .failed
            run.failure = .unknownOutcome(stage: "restart")
            run.finishedAt = now()
            try await store.saveRun(run)
        }
        var settings = try await store.settings()
        do {
            try await vault.ensureHMACKey()
            settings.hmacKeyAvailable = true
        } catch {
            settings.hmacKeyAvailable = false
        }
        try await store.saveSettings(settings)
    }

    public func close() async {
        await disconnect()
        await store.close()
    }

    public var isConnected: Bool {
        get async { await connection?.session.isConnected ?? false }
    }

    func disconnect() async {
        if let connection {
            await connection.tunnel.close()
            await connection.session.close()
        }
        connection = nil
    }

    // MARK: Settings

    public func settings() async throws -> OSINTSettings { try await store.settings() }

    public func saveSettings(_ settings: OSINTSettings) async throws { try await store.saveSettings(settings) }

    /// Host, port, login and (optionally) the password. Another host or login forgets the trusted key.
    public func saveConnection(host: String, port: Int, login: String, password: String?) async throws {
        var settings = try await store.settings()
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLogin = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanLogin.isEmpty, (1...65535).contains(port) else { throw OSINTFailure.invalidInput("connection") }
        if cleanHost != settings.host || cleanLogin != settings.login || port != settings.port {
            if cleanHost != settings.host || cleanLogin != settings.login {
                // Another server: its key is unknown, nothing is installed there yet, and the sketches of the old
                // server mean nothing to it. The attempt journal stays.
                settings.hostKeyFingerprint = nil
                settings.installedSHA = nil
                settings.installedTag = nil
                settings.installedAt = nil
                settings.imageIDs = [:]
                settings.investigationID = nil
                settings.envBackupAvailable = true
                settings.serverID = UUID()
                serverKeyNames = []
                try await store.removeAllSketches()
            }
            await disconnect()
        }
        settings.host = cleanHost
        settings.port = port
        settings.login = cleanLogin
        if let password { try await vault.saveSSHPassword(password) }
        try await store.saveSettings(settings)
    }

    public func servicePassword() async throws -> String? { try await vault.servicePassword() }

    /// The user types the flowsint service password (another Mac, a lost Keychain): stored, then checked.
    public func setServicePassword(_ password: String) async throws {
        try await vault.saveServicePassword(password)
        let settings = try await store.settings()
        let link = try await ensureConnected(requireInstalled: false)
        do {
            try await link.api.login(email: settings.serviceEmail, password: password)
        } catch let failure as OSINTFailure where failure == .serviceAuthFailed {
            throw OSINTFailure.serviceAuthFailed
        }
    }

    /// A fresh service user with a suffixed address, when the existing one's password is lost.
    public func registerNewServiceUser() async throws {
        var settings = try await store.settings()
        let link = try await ensureConnected(requireInstalled: false)
        let parts = settings.serviceEmail.split(separator: "@", maxSplits: 1).map(String.init)
        let local = (parts.first ?? "makosh-osint").split(separator: "+").first.map(String.init) ?? "makosh-osint"
        let domain = parts.count > 1 ? parts[1] : "sh-inc.dev"
        let email = "\(local)+\(try FlowsintInstaller.randomHex(3))@\(domain)"
        let password = try FlowsintInstaller.randomAlphanumeric(32)
        guard try await link.api.register(email: email, password: password) else {
            throw OSINTFailure.apiRejected(code: 409, stage: "register")
        }
        try await vault.saveServicePassword(password)
        settings.serviceEmail = email
        try await store.saveSettings(settings)
    }
}

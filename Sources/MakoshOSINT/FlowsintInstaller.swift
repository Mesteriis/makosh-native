import Foundation
import Security

/// Installs or updates flowsint on the server over the SSH session, step by step. Every step
/// first reads the server's state and skips itself when nothing is needed; a failure stops the
/// run and the next run resumes from the first step that is still needed. The journal never
/// carries secrets: they are generated here, stored in the Keychain first and sent over stdin.
public actor FlowsintInstaller {
    private let session: OSINTSSHSession
    private let api: any FlowsintAPI
    private let vault: OSINTCredentialVault
    private let store: OSINTStore
    private let pin: FlowsintPin
    private let now: @Sendable () -> Date
    private let healthTimeout: Duration
    private let healthPoll: Duration

    static let root = "/opt/flowsint"
    static let compose = "cd \(root) && docker compose -f docker-compose.prod.yml -f docker-compose.makosh.yml"
    static let envNames = ["AUTH_SECRET", "MASTER_VAULT_KEY_V1", "NEO4J_PASSWORD", "POSTGRES_PASSWORD"]

    public init(
        session: OSINTSSHSession, api: any FlowsintAPI, vault: OSINTCredentialVault, store: OSINTStore, pin: FlowsintPin = .current,
        now: @escaping @Sendable () -> Date = Date.init, healthTimeout: Duration = .seconds(300), healthPoll: Duration = .seconds(5)
    ) {
        self.session = session
        self.api = api
        self.vault = vault
        self.store = store
        self.pin = pin
        self.now = now
        self.healthTimeout = healthTimeout
        self.healthPoll = healthPoll
    }

    private struct StepFailure: Error {
        var failure: OSINTFailure
        var message: String?
    }

    private enum Outcome {
        case done(String?)
        case skipped(String?)
    }

    public func run(progress: @escaping @Sendable (OSINTInstall) -> Void) async -> OSINTInstall {
        var install = OSINTInstall(
            targetTag: pin.tag, targetSHA: pin.sha, steps: OSINTInstallStepKind.allCases.map { OSINTInstallStep(kind: $0) },
            createdAt: now())
        await record(install, progress)
        for index in install.steps.indices {
            install.steps[index].state = .running
            await record(install, progress)
            do {
                let outcome = try await perform(install.steps[index].kind)
                switch outcome {
                case .done(let message):
                    install.steps[index].state = .done
                    install.steps[index].message = message
                case .skipped(let message):
                    install.steps[index].state = .skipped
                    install.steps[index].message = message
                }
                install.steps[index].finishedAt = now()
            } catch let failure as StepFailure {
                install.steps[index].state = .failed
                install.steps[index].failure = failure.failure
                install.steps[index].message = failure.message
                install.steps[index].finishedAt = now()
                install.state = .failed
                install.finishedAt = now()
                await record(install, progress)
                return install
            } catch let failure as OSINTFailure {
                install.steps[index].state = .failed
                install.steps[index].failure = failure
                install.steps[index].finishedAt = now()
                install.state = .failed
                install.finishedAt = now()
                await record(install, progress)
                return install
            } catch {
                install.steps[index].state = .failed
                install.steps[index].failure = .installFailed(stage: install.steps[index].kind.rawValue)
                install.steps[index].finishedAt = now()
                install.state = .failed
                install.finishedAt = now()
                await record(install, progress)
                return install
            }
            await record(install, progress)
        }
        install.state = .completed
        install.finishedAt = now()
        await record(install, progress)
        return install
    }

    private func record(_ install: OSINTInstall, _ progress: @Sendable (OSINTInstall) -> Void) async {
        try? await store.saveInstall(install)
        progress(install)
    }

    // MARK: Steps

    private func perform(_ kind: OSINTInstallStepKind) async throws -> Outcome {
        switch kind {
        case .connect: return try await connect()
        case .docker: return try await docker()
        case .checkout: return try await checkout()
        case .env: return try await env()
        case .override: return try await override()
        case .build: return try await build()
        case .up: return try await up()
        case .register: return try await register()
        case .investigation: return try await investigation()
        case .record: return try await recordVersion()
        }
    }

    private func connect() async throws -> Outcome {
        guard await session.isConnected else { throw StepFailure(failure: .sshUnreachable, message: "нет соединения") }
        return .skipped("соединение уже установлено")
    }

    private func docker() async throws -> Outcome {
        let docker = try await session.exec("docker version --format '{{.Server.Version}}' && docker compose version --short")
        guard docker.status == 0 else { throw StepFailure(failure: .dockerMissing, message: "docker не отвечает") }
        let git = try await session.exec("git --version")
        guard git.status == 0 else { throw StepFailure(failure: .gitMissing, message: "git не установлен") }
        let versions = docker.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return .done("Docker \(versions.first ?? "?"), Compose \(versions.dropFirst().first ?? "?")")
    }

    private func checkout() async throws -> Outcome {
        let head = try await session.exec("git -C \(Self.root) rev-parse HEAD")
        let current = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.status == 0, current == pin.sha { return .skipped("уже \(pin.tag)") }
        let result: OSINTExecResult
        if head.status != 0 {
            result = try await session.exec(
                "git clone --branch \(pin.tag) --depth 1 \(pin.repository) \(Self.root) && git -C \(Self.root) rev-parse HEAD",
                timeout: .seconds(600))
        } else {
            result = try await session.exec(
                "git -C \(Self.root) fetch --depth 1 origin tag \(pin.tag) && git -C \(Self.root) checkout --detach \(pin.sha) && git -C \(Self.root) rev-parse HEAD",
                timeout: .seconds(600))
        }
        let landed = result.stdout.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard result.status == 0, landed == pin.sha else {
            throw StepFailure(failure: .installFailed(stage: "checkout"), message: "получен не тот коммит")
        }
        return .done("\(pin.tag) (\(pin.sha.prefix(10)))")
    }

    private func env() async throws -> Outcome {
        let exists = try await session.exec("test -f \(Self.root)/.env")
        if exists.status == 0 {
            if try await vault.envSecret(name: "AUTH_SECRET") == nil {
                var settings = try await store.settings()
                settings.envBackupAvailable = false
                try await store.saveSettings(settings)
                return .skipped(".env уже есть; резервная копия секретов недоступна")
            }
            return .skipped(".env уже есть")
        }
        let masterKey = try Self.randomBase64(32)
        let values = [
            "AUTH_SECRET": try Self.randomHex(32),
            "MASTER_VAULT_KEY_V1": "base64:" + masterKey,
            "NEO4J_PASSWORD": try Self.randomAlphanumeric(24),
            "POSTGRES_PASSWORD": try Self.randomAlphanumeric(24),
        ]
        for name in Self.envNames { try await vault.saveEnvSecret(name: name, values[name]!) }
        let text = """
            NODE_ENV=production
            AUTH_SECRET=\(values["AUTH_SECRET"]!)
            MASTER_VAULT_KEY_V1=\(values["MASTER_VAULT_KEY_V1"]!)
            NEO4J_URI_BOLT=bolt://neo4j:7687
            NEO4J_USERNAME=neo4j
            NEO4J_PASSWORD=\(values["NEO4J_PASSWORD"]!)
            POSTGRES_USER=flowsint
            POSTGRES_PASSWORD=\(values["POSTGRES_PASSWORD"]!)
            POSTGRES_DB=flowsint
            REDIS_URL=redis://redis:6379/0
            FLOWSINT_VERSION=\(pin.tag)

            """
        let result = try await session.exec("install -m 600 /dev/stdin \(Self.root)/.env", stdin: Data(text.utf8))
        guard result.status == 0 else { throw StepFailure(failure: .installFailed(stage: "env"), message: "не записан") }
        var settings = try await store.settings()
        settings.envBackupAvailable = true
        try await store.saveSettings(settings)
        return .done("записан")
    }

    private var overrideText: String {
        """
        services:
          api:
            image: flowsint-api:\(pin.sha)
            build:
              context: .
              dockerfile: flowsint-api/Dockerfile
              target: production
          celery:
            image: flowsint-api:\(pin.sha)
          app:
            image: flowsint-app:\(pin.sha)
            build:
              context: ./flowsint-app
              dockerfile: Dockerfile
            ports: !override ["127.0.0.1:5173:8080"]

        """
    }

    private func override() async throws -> Outcome {
        let current = try await session.exec("cat \(Self.root)/docker-compose.makosh.yml")
        if current.status == 0, current.stdout == overrideText { return .skipped("override совпадает") }
        let result = try await session.exec(
            "install -m 644 /dev/stdin \(Self.root)/docker-compose.makosh.yml", stdin: Data(overrideText.utf8))
        guard result.status == 0 else { throw StepFailure(failure: .installFailed(stage: "override"), message: "не записан") }
        return .done("записан")
    }

    private func imagesPresent() async throws -> Bool {
        for image in ["flowsint-api", "flowsint-app"] {
            let result = try await session.exec("docker image inspect --format '{{.Id}}' \(image):\(pin.sha)")
            if result.status != 0 { return false }
        }
        return true
    }

    private func build() async throws -> Outcome {
        if try await imagesPresent() { return .skipped("образы \(pin.sha.prefix(10)) уже собраны") }
        let built = try await session.exec("\(Self.compose) build", timeout: .seconds(1800))
        guard built.status == 0 else { throw StepFailure(failure: .installFailed(stage: "build"), message: "сборка образов не удалась") }
        let pulled = try await session.exec("\(Self.compose) pull postgres redis neo4j", timeout: .seconds(900))
        guard pulled.status == 0 else { throw StepFailure(failure: .installFailed(stage: "build"), message: "образы баз не скачаны") }
        return .done("собраны")
    }

    /// One row of `docker compose ps --format json`.
    struct ComposeService: Decodable {
        var Service: String
        var State: String
        var Health: String?
        var Image: String?
    }

    static let services = ["postgres", "redis", "neo4j", "api", "celery", "app"]

    /// What compose runs now; nil when the command fails or prints nothing parseable.
    private func composeServices() async throws -> [ComposeService]? {
        let result = try await session.exec("\(Self.compose) ps --format json")
        guard result.status == 0 else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if let array = try? JSONDecoder().decode([ComposeService].self, from: Data(text.utf8)) { return array }
        var rows: [ComposeService] = []
        for line in text.split(separator: "\n") {
            guard let row = try? JSONDecoder().decode(ComposeService.self, from: Data(line.utf8)) else { return nil }
            rows.append(row)
        }
        return rows
    }

    /// Every service running and healthy, and the application services on the pinned images.
    private func stackRunsPinnedImages() async -> Bool {
        guard let services = try? await composeServices(), !services.isEmpty else { return false }
        for name in Self.services {
            guard let row = services.first(where: { $0.Service == name }), row.State == "running",
                (row.Health ?? "").isEmpty || row.Health == "healthy"
            else { return false }
            let expected: String? =
                switch name {
                case "api", "celery": "flowsint-api:\(pin.sha)"
                case "app": "flowsint-app:\(pin.sha)"
                default: nil
                }
            if let expected, row.Image != expected { return false }
        }
        return true
    }

    private func healthy() async -> Bool {
        guard await stackRunsPinnedImages() else { return false }
        return (try? await api.health()) == true
    }

    private func up() async throws -> Outcome {
        if await healthy() { return .skipped("уже работает") }
        let result = try await session.exec("\(Self.compose) up -d --remove-orphans", timeout: .seconds(600))
        guard result.status == 0 else { throw StepFailure(failure: .installFailed(stage: "up"), message: "compose up не удался") }
        let deadline = ContinuousClock.now + healthTimeout
        while ContinuousClock.now < deadline {
            if await healthy() { return .done("работает") }
            try? await Task.sleep(for: healthPoll)
        }
        throw StepFailure(failure: .healthTimeout, message: "службы не ответили вовремя")
    }

    private func register() async throws -> Outcome {
        let settings = try await store.settings()
        if let password = try await vault.servicePassword() {
            do {
                try await api.login(email: settings.serviceEmail, password: password)
                return .skipped("служебный пользователь входит")
            } catch let failure as OSINTFailure where failure == .serviceAuthFailed {
                throw StepFailure(failure: .serviceAuthFailed, message: "пароль служебного пользователя не подходит")
            }
        }
        let password = try Self.randomAlphanumeric(32)
        try await vault.saveServicePassword(password)
        if try await api.register(email: settings.serviceEmail, password: password) { return .done("зарегистрирован") }
        do {
            try await api.login(email: settings.serviceEmail, password: password)
            return .done("вошёл")
        } catch let failure as OSINTFailure where failure == .serviceAuthFailed {
            throw StepFailure(failure: .serviceAuthFailed, message: "пользователь уже есть, пароль неизвестен")
        }
    }

    private func investigation() async throws -> Outcome {
        var settings = try await store.settings()
        let existing = try await api.investigations()
        if let id = settings.investigationID, existing.contains(where: { $0.id == id }) { return .skipped("расследование есть") }
        let investigation: FlowsintInvestigation
        if let found = existing.first(where: { $0.name == "Makosh" }) {
            investigation = found
        } else {
            investigation = try await api.createInvestigation(name: "Makosh")
        }
        settings.investigationID = investigation.id
        try await store.saveSettings(settings)
        return .done("расследование «Makosh»")
    }

    private func recordVersion() async throws -> Outcome {
        var settings = try await store.settings()
        var ids: [String: String] = [:]
        for image in ["flowsint-api", "flowsint-app"] {
            let result = try await session.exec("docker image inspect --format '{{.Id}}' \(image):\(pin.sha)")
            if result.status == 0 { ids[image] = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        settings.installedTag = pin.tag
        settings.installedSHA = pin.sha
        settings.installedAt = now()
        settings.imageIDs = ids
        try await store.saveSettings(settings)
        return .done("\(pin.tag)")
    }

    // MARK: Random values

    private static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw StepFailure(failure: .installFailed(stage: "env"), message: "нет случайных байт")
        }
        return bytes
    }
    static func randomHex(_ count: Int) throws -> String { try randomBytes(count).map { String(format: "%02x", $0) }.joined() }
    static func randomBase64(_ count: Int) throws -> String { try Data(randomBytes(count)).base64EncodedString() }
    static func randomAlphanumeric(_ length: Int) throws -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        // Rejection sampling keeps every character equally likely.
        var result = ""
        while result.count < length {
            for byte in try randomBytes(length) where byte < 248 && result.count < length { result.append(alphabet[Int(byte) % 62]) }
        }
        return result
    }
}

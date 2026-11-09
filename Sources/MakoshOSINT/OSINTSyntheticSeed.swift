#if DEBUG
import Foundation
import MakoshCore

/// The OSINT part of the isolated Persons QA: a scripted SSH server standing in for LXC 164, a synthetic
/// flowsint with Anna's findings, one completed run for Anna and one launch for Boris whose outcome stays unknown.
public enum OSINTSyntheticSeed {
    public static let login = "makosh"
    /// The fixture's SSH password: a QA constant, not a secret.
    public static let password = "qa-synthetic-ssh"
    public static let annaEmail = "anna@sidorov.ru"
    public static let annaUsername = "anna"
    public static let annaPhone = "+79161000001"
    public static let hibpKeyName = "HIBP_API_KEY"
    public static let veriphoneKeyName = "VERIPHONE_API_KEY"

    public static func findings() -> [FlowsintSynthetic.Finding] {
        [
            .init(
                enricher: .emailToGravatar, inputType: .email, inputValue: annaEmail, outputType: .gravatar, outputValue: "hash-anna",
                properties: ["src": .string("https://www.gravatar.com/avatar/hash-anna"), "exists": .bool(true)], edgeLabel: "HAS_GRAVATAR"),
            .init(
                enricher: .emailToBreaches, inputType: .email, inputValue: annaEmail, outputType: .breach, outputValue: "Adobe",
                properties: ["title": .string("Adobe"), "breachdate": .string("2013-10-04")], edgeLabel: "FOUND_IN_BREACH"),
            .init(
                enricher: .usernameToMaigret, inputType: .username, inputValue: annaUsername, outputType: .socialAccount,
                outputValue: "github:anna",
                properties: ["platform": .string("github"), "profile_url": .string("https://github.com/anna")], edgeLabel: "HAS_ACCOUNT"),
            .init(
                enricher: .usernameToMaigret, inputType: .username, inputValue: annaUsername, outputType: .socialAccount,
                outputValue: "twitter:anna",
                properties: ["platform": .string("twitter"), "profile_url": .string("https://twitter.com/anna")], edgeLabel: "HAS_ACCOUNT"),
            .init(
                enricher: .phoneToCarrier, inputType: .phone, inputValue: annaPhone, outputType: .phone, outputValue: annaPhone,
                properties: ["carrier": .string("МТС"), "country": .string("RU"), "line_type": .string("mobile")], edgeLabel: "SAME_PHONE"),
        ]
    }

    /// A loopback SSH server scripted like LXC 164 before installation; `docker compose up` installs the synthetic flowsint.
    public static func scriptedServer(synthetic: FlowsintSynthetic) -> (OSINTSyntheticSSHServer, OSINTScriptedServerState) {
        let state = OSINTScriptedServerState()
        state.onUp = { _Concurrency.Task { await synthetic.setInstalled(true) } }
        let server = OSINTSyntheticSSHServer(login: login, password: password, script: state.script)
        return (server, state)
    }

    /// Connects, trusts, enables, installs, stores a synthetic HIBP key, enriches Anna and leaves Boris's launch unknown.
    /// Idempotent: a person with a sketch is not enriched again, an installed server is not reinstalled.
    public static func seed(
        service: OSINTService, synthetic: FlowsintSynthetic, persons: PersonStore, annaID: UUID, borisID: UUID?, host: String, port: Int,
        trustHostKey: Bool = true
    ) async throws {
        var settings = try await service.settings()
        if settings.host != host || settings.port != port || settings.login != login {
            try await service.saveConnection(host: host, port: port, login: login, password: password)
            settings = try await service.settings()
        }
        try OSINTQAIsolation.validate(settings: settings, synthetic: true)
        if !settings.enabled {
            settings.enabled = true
            try await service.saveSettings(settings)
        }
        if settings.hostKeyFingerprint == nil {
            _ = try await service.testConnection { _ in trustHostKey }
            settings = try await service.settings()
        }
        if settings.installedSHA == nil {
            let install = try await service.install { _ in }
            guard install.state == .completed else { throw OSINTFailure.installFailed(stage: "qa-seed") }
        }
        let keys = try await service.refreshKeys()
        if !keys.contains(hibpKeyName) { try await service.setKey(name: hibpKeyName, value: "synthetic-hibp-key") }
        if !keys.contains(veriphoneKeyName) { try await service.setKey(name: veriphoneKeyName, value: "synthetic-veriphone-key") }
        let sketched = Set(try await service.snapshot().sketches.keys)
        if !sketched.contains(annaID) {
            let inputs = try await service.inputs(personID: annaID)
            try await service.enrich(
                personID: annaID, enrichers: OSINTEnricher.manualDefault.union([.emailToBreaches, .phoneToCarrier]), inputs: inputs)
            await service.settled()
        }
        if let borisID, !sketched.contains(borisID) {
            let inputs = try await service.inputs(personID: borisID).filter { $0.type == .email }
            await synthetic.failNext(.unknownOutcome(stage: "launch"), stage: "launch")
            try await service.enrich(personID: borisID, enrichers: [.emailToGravatar], inputs: inputs)
            await service.settled()
        }
    }
}
#endif

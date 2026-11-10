import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshOSINT

/// A live check against the user's own server, run only on the user's command through the environment:
/// `MAKOSH_OSINT_LIVE_HOST`, `_PORT` (22), `_LOGIN`, `_PASSWORD_FILE` (mode 0600, never printed), `_FINGERPRINT`
/// (the host key verified out of band), `_DATABASE_CONFIG` (`{connectionString, schema}` of the application),
/// `_NAME`, `_EMAILS` and `_USERNAMES` (comma separated) of the person to enrich, `_ENRICHERS` (server names, comma
/// separated; default Gravatar, HudsonRock, Maigret), `_KIND` (`organization`) and `_DOMAINS` for an organization's
/// own domains. Without the host it is skipped.
/// It drives the same `OSINTService` the application uses; the log carries steps, states and codes, and the
/// findings proposed for the chosen person — the user's own data, printed at their request.
final class OSINTLiveCheckTests: XCTestCase {
    private func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment["MAKOSH_OSINT_LIVE_" + name].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func log(_ line: String) { print("LIVE: \(line)") }

    private struct Configuration: Decodable {
        var connectionString: String
        var schema: String?
    }

    func testLiveInstallAndEnrich() async throws {
        guard let host = env("HOST") else { throw XCTSkip("the live check runs only on the user's command") }
        let login = try XCTUnwrap(env("LOGIN"))
        let expected = try XCTUnwrap(env("FINGERPRINT"))
        let passwordFile = try XCTUnwrap(env("PASSWORD_FILE"))
        let configFile = try XCTUnwrap(env("DATABASE_CONFIG"))
        let name = env("NAME") ?? "OSINT live check"
        let emails = (env("EMAILS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let usernames = (env("USERNAMES") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty
        }
        let port = Int(env("PORT") ?? "22") ?? 22
        let domains = (env("DOMAINS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter {
            !$0.isEmpty
        }
        let kind: PersonKind = env("KIND") == "organization" ? .organization : .person
        let named = (env("ENRICHERS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let chosen = Set(named.compactMap(OSINTEnricher.init(rawValue:)))
        XCTAssertEqual(chosen.count, named.count, "every name in _ENRICHERS is an enricher Makosh knows")
        let attributes = try FileManager.default.attributesOfItem(atPath: passwordFile)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o077, 0o600, "the password file is private")
        let password = try String(contentsOfFile: passwordFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: configFile)))
        let schema = configuration.schema ?? "makosh"

        let persons = try PersonStore(connectionString: configuration.connectionString, schema: schema)
        let store = OSINTStore(connectionString: configuration.connectionString, schema: schema)
        let vault = OSINTCredentialVault(access: .system)
        let (session, api) = OSINTService.liveFactories()
        let service = OSINTService(
            persons: persons, store: store, vault: vault, sessionFactory: session, apiFactory: api, scanTimeout: .seconds(900),
            pollInterval: .seconds(3), healthPoll: .seconds(5))
        try await service.open()
        defer { _Concurrency.Task { await service.close() } }

        // 1. Connection: the saved password, the module on, the key trusted only when it equals the verified one.
        try await service.saveConnection(host: host, port: port, login: login, password: password)
        var settings = try await service.settings()
        settings.enabled = true
        try await service.saveSettings(settings)
        let report = try await service.testConnection { offered in offered == expected }
        log(
            "connection: fingerprint matches=\(report.fingerprint == expected) docker=\(report.dockerPresent.map(String.init) ?? "?") checkedOut=\(report.checkedOutSHA?.prefix(7) ?? "none") healthy=\(report.healthy.map(String.init) ?? "?")"
        )
        XCTAssertEqual(report.fingerprint, expected)

        // 2. Installation through the installer the settings button uses.
        let started = ContinuousClock.now
        let install = try await service.install { progress in
            for step in progress.steps where step.state == .running { print("LIVE: step \(step.kind.rawValue) running") }
        }
        for step in install.steps {
            log(
                "step \(step.kind.rawValue): \(step.state.rawValue)\(step.message.map { " — \($0)" } ?? "")\(step.failure.map { " — \($0.code)" } ?? "")"
            )
        }
        log("install \(install.state.rawValue) in \(Int((ContinuousClock.now - started) / .seconds(1))) s")
        XCTAssertEqual(install.state, .completed)
        settings = try await service.settings()
        log(
            "installed tag=\(settings.installedTag ?? "none") sha=\(settings.installedSHA?.prefix(7) ?? "none") investigation=\(settings.investigationID ?? "none")"
        )
        let keyNames = try await service.refreshKeys()
        log("server keys: \(keyNames.sorted())")

        // 3. The person: an existing one owning one of the addresses, else a new card with the given values.
        let all = try persons.persons()
        let normalized = Set(emails.map(PersonMatching.normalizedEmail))
        let personID: UUID
        let match: (Person) -> Bool = { candidate in
            guard candidate.kind == kind else { return false }
            if normalized.isEmpty { return candidate.displayName == name }
            return !Set(candidate.emails.map(PersonMatching.normalizedEmail)).isDisjoint(with: normalized)
        }
        if let existing = all.first(where: match) {
            personID = existing.id
            log("person: existing «\(existing.displayName)»")
        } else {
            personID = try persons.createPerson(draft: PersonDraft(kind: kind, displayName: name, emails: emails, usernames: usernames))
            log("person: created «\(name)»")
        }
        let enrichers: Set<OSINTEnricher> = chosen.isEmpty ? [.emailToGravatar, .emailToHudsonRock, .usernameToMaigret] : chosen
        let wanted = Set(enrichers.map(\.inputType))
        // The dossier's own values of the types the chosen enrichers take, plus the organization's domains named here.
        var inputs = try await service.inputs(personID: personID).filter { wanted.contains($0.type) }
        for domain in domains where !inputs.contains(OSINTInput(type: .domain, value: domain)) {
            inputs.append(OSINTInput(type: .domain, value: domain))
        }
        log("inputs: \(inputs.map { "\($0.type.rawValue)=\($0.value)" })")
        XCTAssertFalse(inputs.isEmpty)

        // 4. One manual run with the chosen enrichers.
        log("enrichers: \(enrichers.map(\.rawValue).sorted())")
        let runStarted = ContinuousClock.now
        let runID = try await service.enrich(personID: personID, enrichers: enrichers, inputs: inputs)
        await service.settled()
        let run = try await store.run(id: runID)
        log(
            "run \(run?.state.rawValue ?? "?") found=\(run?.found ?? -1) truncated=\(run?.truncated ?? false) failure=\(run?.failure?.code ?? "none") in \(Int((ContinuousClock.now - runStarted) / .seconds(1))) s"
        )
        let attempts = try await store.attempts(runID: runID)
        for attempt in attempts {
            log(
                "attempt \(attempt.kind.rawValue) \(attempt.payload.enricher?.rawValue ?? "") → \(attempt.state.rawValue)\(attempt.failure.map { " \($0.code)" } ?? "")"
            )
        }
        let person = try XCTUnwrap(persons.person(id: personID))
        let proposals = person.observations.filter { $0.source.identity.service == OSINTGraphMapping.service && $0.status == .proposed }
        log("proposals: \(proposals.count), new in this run: \(run?.found ?? 0)")
        for item in proposals { log("  \(item.field): \(item.value)  [\(item.source.identity.externalID)]") }
        if let url = try await service.graphURL(personID: personID) { log("graph: \(url.path)") }
        XCTAssertNotEqual(run?.state, .failed, run?.failure?.code ?? "")
    }
}

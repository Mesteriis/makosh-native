import Foundation
import MakoshCore

extension OSINTService {
    // MARK: Third-party API keys

    /// Reads the names the server holds (values never come back) and caches them for the snapshot.
    @discardableResult
    public func refreshKeys() async throws -> Set<String> {
        let link = try await ensureConnected(requireInstalled: false)
        let names = Set(try await link.api.keys().map(\.name))
        serverKeyNames = names
        if let offered = try? await link.api.enrichers() { serverEnricherNames = Set(offered) }
        return names
    }

    /// Stores the key in the Keychain and in the server's vault, replacing an older key of the same name.
    public func setKey(name: String, value: String) async throws {
        guard OSINTEnricher.knownKeys.contains(name) else { throw OSINTFailure.invalidInput("key name") }
        let link = try await ensureConnected(requireInstalled: false)
        for existing in try await link.api.keys() where existing.name == name {
            // The old key must be gone for certain before a new one appears: two keys of one name is an anti-goal.
            let outcome = try await keyAttempt(
                kind: .deleteKey, name: name,
                {
                    try await link.api.deleteKey(id: existing.id)
                    return existing.id
                })
            guard outcome.state == .confirmed else { throw outcome.failure ?? OSINTFailure.unknownOutcome(stage: "deleteKey") }
        }
        try await vault.saveKey(name: name, value)
        let created = try await keyAttempt(kind: .createKey, name: name, { try await link.api.createKey(name: name, value: value).id })
        serverKeyNames = Set(try await link.api.keys().map(\.name))
        if created.state != .confirmed { throw created.failure ?? OSINTFailure.unknownOutcome(stage: "createKey") }
    }

    public func removeKey(name: String) async throws {
        let link = try await ensureConnected(requireInstalled: false)
        for existing in try await link.api.keys() where existing.name == name {
            try await keyAttempt(
                kind: .deleteKey, name: name,
                {
                    try await link.api.deleteKey(id: existing.id)
                    return existing.id
                })
        }
        try await vault.removeKey(name: name)
        serverKeyNames = Set(try await link.api.keys().map(\.name))
    }

    /// One journaled key write; a journal row that cannot be saved throws before anything is sent.
    @discardableResult
    private func keyAttempt(
        kind: OSINTAttemptKind, name: String, _ call: () async throws -> String
    ) async throws -> (state: OSINTAttemptState, failure: OSINTFailure?) {
        var attempt = OSINTAttempt(kind: kind, payload: OSINTAttemptPayload(keyName: name), createdAt: now())
        do {
            try await store.saveAttempt(attempt)
            attempt.state = .sent
            try await store.saveAttempt(attempt)
        } catch {
            throw Self.journalFailure(error, stage: kind.rawValue)
        }
        do {
            let id = try await call()
            attempt.state = .confirmed
            attempt.response = OSINTAttemptResponse(keyID: id)
        } catch {
            let failure = Self.failure(error, stage: kind.rawValue)
            attempt.state = Self.isUnknown(failure) ? .unknown : .rejected
            attempt.failure = failure
        }
        do { try await store.saveAttempt(attempt) } catch { lastFailure = Self.journalFailure(error, stage: kind.rawValue) }
        return (attempt.state, attempt.failure)
    }

    // MARK: Proposals

    public func acceptObservation(personID: UUID, observationID: UUID) async throws -> PersonAcceptOutcome {
        try persons.acceptObservation(personID: personID, observationID: observationID)
    }

    public func rejectObservation(personID: UUID, observationID: UUID) async throws {
        try persons.setObservationStatus(personID: personID, observationID: observationID, status: .rejected)
    }

    // MARK: Snapshot and links

    public func snapshot() async throws -> OSINTSnapshot {
        let settings = try await store.settings()
        var lastRuns: [UUID: OSINTRun] = [:]
        for run in try await store.runs(open: false) {
            if let known = lastRuns[run.personID], (known.createdAt, known.id.uuidString) > (run.createdAt, run.id.uuidString) { continue }
            lastRuns[run.personID] = run
        }
        let sketches = Dictionary(try await store.sketches().map { ($0.personID, $0) }, uniquingKeysWith: { first, _ in first })
        return OSINTSnapshot(
            settings: settings, connected: await isConnected, openAttempts: try await store.attempts(open: true), lastRuns: lastRuns,
            sketches: sketches, serverKeyNames: serverKeyNames, serverEnricherNames: serverEnricherNames,
            lastInstall: try await store.installs().last, installing: installing,
            lastFailure: lastFailure)
    }

    /// The flowsint page of the person's sketch, through the tunnel; nil without a sketch or a connection.
    public func graphURL(personID: UUID) async throws -> URL? {
        guard let sketch = try await store.sketch(personID: personID), sketch.deletedAt == nil else { return nil }
        let settings = try await store.settings()
        guard let investigation = settings.investigationID, let root = try await webRootURL() else { return nil }
        // The frontend route is /dashboard/investigations/$investigationId/$type/$id with type "graph" for a sketch.
        return root.appendingPathComponent("dashboard/investigations/\(investigation)/graph/\(sketch.sketchID)")
    }

    /// The flowsint web interface through the tunnel (the user signs in with the service password).
    public func webRootURL() async throws -> URL? {
        let link = try await ensureConnected(requireInstalled: false)
        return link.tunnel.baseURL
    }
}

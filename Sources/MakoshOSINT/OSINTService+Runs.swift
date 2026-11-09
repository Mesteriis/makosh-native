import Foundation
import MakoshCore

/// One value the run sends to the server: an address, a phone, a username or the name.
public struct OSINTInput: Codable, Hashable, Sendable {
    public var type: FlowsintNodeType
    public var value: String
    public init(type: FlowsintNodeType, value: String) {
        self.type = type
        self.value = value
    }
    /// The comparison form: addresses lower case, phones as "+digits", the rest trimmed lower case.
    var normalized: OSINTInput { OSINTInput(type: type, value: OSINTService.normalized(type, value)) }
}

extension OSINTService {
    static func normalized(_ type: FlowsintNodeType, _ value: String) -> String {
        switch type {
        case .email: PersonMatching.normalizedEmail(value)
        case .phone:
            PersonMatching.normalizedPhone(value).isEmpty
                ? value.trimmingCharacters(in: .whitespacesAndNewlines) : "+" + PersonMatching.normalizedPhone(value)
        default: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// What a run may send: the dossier's current addresses, phones, usernames and the name. Never
    /// notes, tags, titles or proposals.
    public func inputs(personID: UUID) async throws -> [OSINTInput] {
        guard let person = try persons.person(id: personID) else { throw OSINTFailure.invalidInput("person") }
        var result: [OSINTInput] = []
        var seen = Set<OSINTInput>()
        func add(_ type: FlowsintNodeType, _ raw: String) {
            let value: String
            switch type {
            case .email: value = PersonMatching.normalizedEmail(raw)
            case .phone:
                let digits = PersonMatching.normalizedPhone(raw)
                value = digits.isEmpty ? "" : "+" + digits
            default: value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let input = OSINTInput(type: type, value: value)
            guard !value.isEmpty, seen.insert(input.normalized).inserted else { return }
            result.append(input)
        }
        for email in person.emails { add(.email, email) }
        for phone in person.phones { add(.phone, phone) }
        for username in person.usernames { add(.username, username) }
        add(person.kind == .organization ? .organization : .individual, person.displayName)
        return result
    }

    /// Queues one enrichment; the runner takes it when the previous run is done. Manual runs go first.
    @discardableResult
    public func enrich(
        personID: UUID, enrichers: Set<OSINTEnricher>, inputs: [OSINTInput], trigger: OSINTRunTrigger = .manual
    ) async throws -> UUID {
        let settings = try await store.settings()
        guard settings.enabled else { throw OSINTFailure.disabled }
        guard settings.hostKeyFingerprint != nil else { throw OSINTFailure.hostKeyMismatch }
        guard settings.installedSHA != nil else { throw OSINTFailure.notInstalled }
        guard let person = try persons.person(id: personID), person.isActive else { throw OSINTFailure.invalidInput("person") }
        guard !enrichers.isEmpty, !inputs.isEmpty else { throw OSINTFailure.invalidInput("empty run") }
        let run = OSINTRun(personID: personID, trigger: trigger, enrichers: enrichers, createdAt: now())
        try await store.saveRun(run)
        pendingInputs[run.id] = inputs
        kick()
        return run.id
    }

    public func lastRun(personID: UUID) async throws -> OSINTRun? { try await store.lastRun(personID: personID) }
    public func attempts(runID: UUID) async throws -> [OSINTAttempt] { try await store.attempts(runID: runID) }

    /// Waits until the runner has nothing queued (tests and QA).
    public func settled() async {
        guard runner != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func kick() {
        guard runner == nil else { return }
        runner = _Concurrency.Task { await self.drain() }
    }

    private func drain() async {
        while let run = await nextQueued() { await execute(run) }
        runner = nil
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func nextQueued() async -> OSINTRun? {
        guard let runs = try? await store.runs(open: true) else { return nil }
        return runs.filter { $0.state == .queued }.min { lhs, rhs in
            (lhs.trigger.isAutomatic ? 1 : 0, lhs.createdAt, lhs.id.uuidString) < (
                rhs.trigger.isAutomatic ? 1 : 0, rhs.createdAt, rhs.id.uuidString
            )
        }
    }

    // MARK: One run

    static func failure(_ error: Error, stage: String) -> OSINTFailure {
        (error as? OSINTFailure) ?? .unknownOutcome(stage: stage)
    }

    static func isUnknown(_ failure: OSINTFailure) -> Bool {
        switch failure {
        case .unknownOutcome, .sshUnreachable: true
        default: false
        }
    }

    private func finish(_ run: OSINTRun, state: OSINTRunState, failure: OSINTFailure?) async {
        var run = run
        run.state = state
        run.failure = failure
        run.finishedAt = now()
        try? await store.saveRun(run)
        if let failure, state == .failed { lastFailure = failure }
    }

    /// Writes an attempt through `queued → sent`, runs the call, records the outcome and returns its value.
    private func attempt<T: Sendable>(
        _ attempt: OSINTAttempt, stage: String, _ call: () async throws -> T, response: (T) -> OSINTAttemptResponse
    ) async -> T? {
        var record = attempt
        try? await store.saveAttempt(record)
        record.state = .sent
        try? await store.saveAttempt(record)
        do {
            let value = try await call()
            record.state = .confirmed
            record.response = response(value)
            try? await store.saveAttempt(record)
            return value
        } catch {
            let failure = Self.failure(error, stage: stage)
            record.state = Self.isUnknown(failure) ? .unknown : .rejected
            record.failure = failure
            try? await store.saveAttempt(record)
            return nil
        }
    }

    private func execute(_ queued: OSINTRun) async {
        var run = queued
        run.state = .running
        run.startedAt = now()
        try? await store.saveRun(run)
        guard let inputs = pendingInputs.removeValue(forKey: run.id) else {
            await finish(run, state: .failed, failure: .invalidInput("inputs lost"))
            return
        }
        let link: Connection
        do {
            link = try await ensureConnected()
        } catch {
            await finish(run, state: .failed, failure: Self.failure(error, stage: "connect"))
            return
        }
        guard let settings = try? await store.settings() else {
            await finish(run, state: .failed, failure: .storage("settings"))
            return
        }

        // 1. The person's sketch. A storage error is not a missing sketch: a second sketch would be an anti-goal.
        let sketchID: String
        let existingLink: OSINTSketchLink?
        do {
            existingLink = try await store.sketch(personID: run.personID)
        } catch {
            await finish(run, state: .failed, failure: .storage("sketch"))
            return
        }
        if let existing = existingLink, existing.deletedAt == nil {
            sketchID = existing.sketchID
        } else {
            guard let investigation = settings.investigationID else {
                await finish(run, state: .failed, failure: .notInstalled)
                return
            }
            let personID = run.personID
            let created = await attempt(
                OSINTAttempt(runID: run.id, personID: personID, kind: .createSketch, payload: OSINTAttemptPayload(), createdAt: now()),
                stage: "createSketch", { try await link.api.createSketch(title: personID.uuidString, investigationID: investigation) },
                response: { OSINTAttemptResponse(sketchID: $0.id) })
            guard let created else {
                let open = (try? await store.attempts(runID: run.id))?.contains { $0.state == .unknown } ?? false
                await finish(run, state: open ? .unknown : .failed, failure: .unknownOutcome(stage: "createSketch"))
                return
            }
            try? await store.saveSketch(OSINTSketchLink(personID: personID, sketchID: created.id, createdAt: now()))
            try? persons.attachIdentity(personID: personID, OSINTGraphMapping.identity(serverID: settings.serverID, sketchID: created.id))
            sketchID = created.id
        }

        // 2. Nodes already in the graph.
        var nodeIDs: [OSINTInput: String] = [:]
        if let graph = try? await link.api.graph(sketchID: sketchID) {
            for node in graph.nodes {
                guard let type = FlowsintNodeType(wireType: node.type), let primary = node.primaryValue else { continue }
                nodeIDs[OSINTInput(type: type, value: Self.normalized(type, primary))] = node.id
            }
        }

        // 3. The run's inputs as nodes.
        for input in inputs where nodeIDs[input.normalized] == nil {
            let digest = try? await vault.hmac(input.value)
            let id = await attempt(
                OSINTAttempt(
                    runID: run.id, personID: run.personID, kind: .addNode,
                    payload: OSINTAttemptPayload(sketchID: sketchID, nodeType: input.type, valueHMAC: digest), createdAt: now()),
                stage: "addNode", { try await link.api.addNode(sketchID: sketchID, type: input.type, value: input.value) },
                response: { OSINTAttemptResponse(nodeID: $0) })
            if let id { nodeIDs[input.normalized] = id }
        }

        // 4. One launch per (node, compatible enricher); keyed enrichers only when the server has the key.
        let keyNames = Set(((try? await link.api.keys()) ?? []).map(\.name))
        var scans: [(attemptID: UUID, scanID: String)] = []
        for input in inputs {
            guard let nodeID = nodeIDs[input.normalized] else { continue }
            for enricher in run.enrichers.sorted(by: { $0.rawValue < $1.rawValue }) where enricher.inputType == input.type {
                if let key = enricher.requiredKey, !keyNames.contains(key) { continue }
                // A launch stays `sent` until its task ends: the poll below confirms, rejects or leaves it unknown.
                var record = OSINTAttempt(
                    runID: run.id, personID: run.personID, kind: .launch,
                    payload: OSINTAttemptPayload(sketchID: sketchID, enricher: enricher, inputNodeID: nodeID), createdAt: now())
                try? await store.saveAttempt(record)
                record.state = .sent
                try? await store.saveAttempt(record)
                do {
                    let scanID = try await link.api.launch(enricher: enricher, sketchID: sketchID, nodeIDs: [nodeID])
                    record.response = OSINTAttemptResponse(scanID: scanID)
                    try? await store.saveAttempt(record)
                    scans.append((record.id, scanID))
                } catch {
                    let failure = Self.failure(error, stage: "launch")
                    await settle(attemptID: record.id, state: Self.isUnknown(failure) ? .unknown : .rejected, failure: failure)
                }
            }
        }

        // 5. Wait for the tasks, not forever.
        let deadline = ContinuousClock.now + scanTimeout
        var pending = scans
        while !pending.isEmpty, ContinuousClock.now < deadline {
            var still: [(attemptID: UUID, scanID: String)] = []
            for item in pending {
                do {
                    switch try await link.api.scan(id: item.scanID) {
                    case .completed: await settle(attemptID: item.attemptID, state: .confirmed, failure: nil)
                    case .failed: await settle(attemptID: item.attemptID, state: .rejected, failure: .apiRejected(code: 500, stage: "scan"))
                    case .pending, .running: still.append(item)
                    }
                } catch {
                    let failure = Self.failure(error, stage: "scan")
                    if Self.isUnknown(failure) {
                        still.append(item)
                    } else {
                        await settle(attemptID: item.attemptID, state: .rejected, failure: failure)
                    }
                }
            }
            pending = still
            if !pending.isEmpty { try? await _Concurrency.Task.sleep(for: pollInterval) }
        }
        for item in pending { await settle(attemptID: item.attemptID, state: .unknown, failure: .unknownOutcome(stage: "scan")) }

        // 6. What the graph now holds, as proposals: only what hangs off this run's own input nodes.
        do {
            let graph = try await link.api.graph(sketchID: sketchID)
            if let person = try? persons.person(id: run.personID), person.isActive {
                let mapped = OSINTGraphMapping.observations(
                    graph: graph, inputNodeIDs: Set(inputs.compactMap { nodeIDs[$0.normalized] }), sketchID: sketchID,
                    serverID: settings.serverID, person: person, now: now())
                run.found = (try? persons.addProposedObservations(personID: run.personID, mapped.observations)) ?? 0
                run.truncated = mapped.truncated
            }
        } catch {
            await finish(run, state: .failed, failure: Self.failure(error, stage: "graph"))
            return
        }

        // 7. Closed when every attempt is closed.
        let open = ((try? await store.attempts(runID: run.id)) ?? []).contains { $0.state.isOpen }
        await finish(run, state: open ? .unknown : .completed, failure: open ? .unknownOutcome(stage: "run") : nil)
    }

    func settle(attemptID: UUID, state: OSINTAttemptState, failure: OSINTFailure?) async {
        guard var record = try? await store.attempt(id: attemptID) else { return }
        record.state = state
        record.failure = failure
        try? await store.saveAttempt(record)
    }
}

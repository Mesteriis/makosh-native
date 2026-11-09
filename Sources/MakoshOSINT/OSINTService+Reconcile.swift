import Foundation
import MakoshCore

extension OSINTService {
    // MARK: Unknown attempts

    /// Settles an unknown attempt by reading the server, never by sending again.
    public func settle(attemptID: UUID) async throws {
        guard let attempt = try await store.attempt(id: attemptID), attempt.state == .unknown else { return }
        let link = try await ensureConnected(requireInstalled: false)
        let settings = try await store.settings()
        try await settle(attempt, link: link, settings: settings)
    }

    private func settle(_ attempt: OSINTAttempt, link: Connection, settings: OSINTSettings) async throws {
        var record = attempt
        var closed = false
        switch attempt.kind {
        case .createSketch:
            guard let personID = attempt.personID, let investigation = settings.investigationID else { return }
            if let sketch = try await link.api.sketches(investigationID: investigation).first(where: { $0.title == personID.uuidString }) {
                record.state = .confirmed
                record.response = OSINTAttemptResponse(sketchID: sketch.id)
                let existing = try await store.sketch(personID: personID)
                if existing == nil || existing?.deletedAt != nil {
                    try await store.saveSketch(OSINTSketchLink(personID: personID, sketchID: sketch.id, createdAt: now()))
                }
                try? persons.attachIdentity(
                    personID: personID, OSINTGraphMapping.identity(serverID: settings.serverID, sketchID: sketch.id))
                closed = true
            }
        case .addNode:
            guard let sketchID = attempt.payload.sketchID, let type = attempt.payload.nodeType, let digest = attempt.payload.valueHMAC
            else { return }
            let graph = try await link.api.graph(sketchID: sketchID)
            for node in graph.nodes where node.type == type.rawValue {
                guard let primary = node.primaryValue, let candidate = try await vault.hmac(primary), candidate == digest else { continue }
                record.state = .confirmed
                record.response = OSINTAttemptResponse(nodeID: node.id)
                closed = true
                break
            }
        case .launch:
            guard let sketchID = attempt.payload.sketchID, let inputNodeID = attempt.payload.inputNodeID,
                let enricher = attempt.payload.enricher
            else { return }
            let graph = try await link.api.graph(sketchID: sketchID)
            let neighbors = graph.edges.compactMap { edge -> String? in
                if edge.source == inputNodeID { return edge.target }
                if edge.target == inputNodeID { return edge.source }
                return nil
            }
            let produced = graph.nodes.contains { node in
                neighbors.contains(node.id) && FlowsintNodeType(wireType: node.type).map { enricher.outputTypes.contains($0) } == true
            }
            if produced {
                record.state = .confirmed
                closed = true
            } else if let scanID = attempt.response?.scanID {
                switch try? await link.api.scan(id: scanID) {
                case .completed?:
                    record.state = .confirmed
                    closed = true
                case .failed?:
                    record.state = .rejected
                    record.failure = .apiRejected(code: 500, stage: "scan")
                    closed = true
                default: break
                }
            }
        case .deleteSketch:
            guard let sketchID = attempt.payload.sketchID else { return }
            let remote = try await link.api.sketch(id: sketchID)
            if remote == nil {
                record.state = .confirmed
                closed = true
                if let personID = attempt.personID, var sketch = try await store.sketch(personID: personID), sketch.sketchID == sketchID {
                    sketch.deletedAt = now()
                    try await store.saveSketch(sketch)
                }
            }
        case .createKey, .deleteKey:
            guard let name = attempt.payload.keyName else { return }
            let keys = try await link.api.keys()
            let present = keys.contains { $0.name == name }
            if present == (attempt.kind == .createKey) {
                record.state = .confirmed
                closed = true
            }
        }
        guard closed else { return }
        record.failure = record.state == .confirmed ? nil : record.failure
        try await store.saveAttempt(record)
        if let runID = attempt.runID { await refreshRun(runID, link: link, settings: settings) }
    }

    /// A run whose attempts are all closed is closed too; findings it never read are proposed now.
    private func refreshRun(_ runID: UUID, link: Connection, settings: OSINTSettings) async {
        guard var run = try? await store.run(id: runID), run.state == .unknown else { return }
        let attempts = (try? await store.attempts(runID: runID)) ?? []
        guard !attempts.contains(where: { $0.state.isOpen }) else { return }
        if run.found == 0, let sketch = try? await store.sketch(personID: run.personID), sketch.deletedAt == nil,
            let person = try? persons.person(id: run.personID), person.isActive,
            let graph = try? await link.api.graph(sketchID: sketch.sketchID)
        {
            // The run's inputs: the nodes it launched from, and the nodes it added.
            let launched = attempts.filter { $0.kind == .launch }.compactMap { $0.payload.inputNodeID }
            let added = attempts.filter { $0.kind == .addNode && $0.state == .confirmed }.compactMap { $0.response?.nodeID }
            let inputs = Set(launched + added)
            let mapped = OSINTGraphMapping.observations(
                graph: graph, inputNodeIDs: inputs, sketchID: sketch.sketchID, serverID: settings.serverID, person: person, now: now())
            run.found = (try? persons.addProposedObservations(personID: run.personID, mapped.observations)) ?? 0
            run.truncated = mapped.truncated
        }
        run.state = .completed
        run.failure = nil
        run.finishedAt = now()
        try? await store.saveRun(run)
    }

    /// The user gives an unknown attempt up: it is rejected, and a run left without open attempts fails.
    public func dismiss(attemptID: UUID) async throws {
        guard var attempt = try await store.attempt(id: attemptID), attempt.state == .unknown else {
            throw OSINTFailure.invalidInput("attempt")
        }
        attempt.state = .rejected
        try await store.saveAttempt(attempt)
        guard let runID = attempt.runID, var run = try await store.run(id: runID), run.state.isOpen else { return }
        let remaining = try await store.attempts(runID: runID)
        guard !remaining.contains(where: { $0.state.isOpen }) else { return }
        run.state = .failed
        run.failure = .unknownOutcome(stage: "run")
        run.finishedAt = now()
        try await store.saveRun(run)
    }

    // MARK: Reconciliation

    /// The periodic pass: cancels automatic runs of books that lost the flag, settles unknown attempts
    /// by reading, deletes sketches of deleted and absorbed persons and queues automatic runs for new
    /// people of flagged books within the hourly limit. Never throws; the last failure is in the snapshot.
    public func reconcile(autoSources: [ImportSource]) async {
        let allowed = Set(autoSources.map { $0.service + "/" + $0.accountID })
        if let runs = try? await store.runs(open: true) {
            for var run in runs where run.state == .queued {
                guard case .book(let source) = run.trigger, !allowed.contains(source.service + "/" + source.accountID) else { continue }
                run.state = .failed
                run.failure = .disabled
                run.finishedAt = now()
                pendingInputs[run.id] = nil
                try? await store.saveRun(run)
            }
        }
        guard let settings = try? await store.settings(), settings.enabled, settings.hostKeyFingerprint != nil else { return }
        let link: Connection
        do {
            link = try await ensureConnected(requireInstalled: false)
        } catch {
            lastFailure = error as? OSINTFailure
            return
        }
        for attempt in (try? await store.attempts(open: true)) ?? [] where attempt.state == .unknown {
            do { try await settle(attempt, link: link, settings: settings) } catch { lastFailure = error as? OSINTFailure }
        }
        for run in (try? await store.runs(open: true)) ?? [] where run.state == .unknown {
            await refreshRun(run.id, link: link, settings: settings)
        }
        await deleteOrphanSketches(link: link)
        guard settings.installedSHA != nil, !autoSources.isEmpty else { return }
        await queueAutomaticRuns(autoSources: autoSources, settings: settings)
    }

    private func deleteOrphanSketches(link: Connection) async {
        guard let links = try? await store.sketches() else { return }
        let open = (try? await store.attempts(open: true)) ?? []
        for sketch in links where sketch.deletedAt == nil {
            // A storage error is not a missing person: the sketch stays until the dossier answers.
            let person: Person?
            do { person = try persons.person(id: sketch.personID) } catch { continue }
            guard person == nil || person?.deletedAt != nil else { continue }
            guard !open.contains(where: { $0.kind == .deleteSketch && $0.personID == sketch.personID }) else { continue }
            await deleteSketch(sketch, link: link)
        }
    }

    /// One journaled `deleteSketch`; a 404 counts as done.
    func deleteSketch(_ sketch: OSINTSketchLink, link: Connection) async {
        var attempt = OSINTAttempt(
            personID: sketch.personID, kind: .deleteSketch, payload: OSINTAttemptPayload(sketchID: sketch.sketchID), createdAt: now())
        try? await store.saveAttempt(attempt)
        attempt.state = .sent
        try? await store.saveAttempt(attempt)
        do {
            try await link.api.deleteSketch(id: sketch.sketchID)
            attempt.state = .confirmed
            try? await store.saveAttempt(attempt)
            var updated = sketch
            updated.deletedAt = now()
            try? await store.saveSketch(updated)
        } catch {
            let failure = Self.failure(error, stage: "deleteSketch")
            attempt.state = Self.isUnknown(failure) ? .unknown : .rejected
            attempt.failure = failure
            try? await store.saveAttempt(attempt)
        }
    }

    private func queueAutomaticRuns(autoSources: [ImportSource], settings: OSINTSettings) async {
        let allowed = Set(autoSources.map { $0.service + "/" + $0.accountID })
        guard let people = try? persons.persons() else { return }
        var used = (try? await store.automaticRunCount(since: now().addingTimeInterval(-3600))) ?? 0
        let dayAgo = now().addingTimeInterval(-86400)
        for person in people.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            guard used < settings.automaticRunsPerHour else { break }
            guard person.kind == .person, person.isActive else { continue }
            guard let identity = person.identities.first(where: { allowed.contains($0.service + "/" + $0.accountID) }) else { continue }
            // Any sketch row, deleted too, means the person was enriched once or the user removed the data:
            // automatic enrichment never repeats it. A storage error skips the person.
            do {
                if try await store.sketch(personID: person.id) != nil { continue }
            } catch { continue }
            if let last = try? await store.lastRun(personID: person.id), last.createdAt > dayAgo { continue }
            guard let inputs = try? await inputs(personID: person.id), !inputs.isEmpty else { continue }
            let source = ImportSource(service: identity.service, accountID: identity.accountID)
            do {
                _ = try await enrich(personID: person.id, enrichers: settings.automaticEnrichers, inputs: inputs, trigger: .book(source))
                used += 1
            } catch {
                lastFailure = error as? OSINTFailure
            }
        }
    }

    // MARK: User commands

    /// Deletes the person's sketch on the server and drops the proposals; confirmed observations stay.
    public func deleteOSINTData(personID: UUID) async throws {
        if let sketch = try await store.sketch(personID: personID), sketch.deletedAt == nil {
            let link = try await ensureConnected(requireInstalled: false)
            await deleteSketch(sketch, link: link)
        }
        try persons.removeObservations(personID: personID, service: OSINTGraphMapping.service)
    }

    /// Queued automatic runs are dropped when the module or a book's flag is switched off.
    public func cancelQueuedAutomaticRuns() async {
        for var run in (try? await store.runs(open: true)) ?? [] where run.state == .queued && run.trigger.isAutomatic {
            run.state = .failed
            run.failure = .disabled
            run.finishedAt = now()
            pendingInputs[run.id] = nil
            try? await store.saveRun(run)
        }
    }
}

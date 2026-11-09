import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

final class OSINTServiceRunTests: XCTestCase {
    private var harnesses: [OSINTServiceHarness] = []
    static let anna = "anna@example.test"

    override func tearDown() async throws {
        for harness in harnesses { await harness.stop() }
        harnesses = []
    }

    static func findings() -> [FlowsintSynthetic.Finding] {
        [
            .init(
                enricher: .emailToGravatar, inputType: .email, inputValue: anna, outputType: .gravatar, outputValue: "hash-anna",
                properties: ["src": .string("https://www.gravatar.com/avatar/hash-anna"), "exists": .bool(true)], edgeLabel: "HAS_GRAVATAR"),
            .init(
                enricher: .emailToBreaches, inputType: .email, inputValue: anna, outputType: .breach, outputValue: "Adobe",
                properties: ["title": .string("Adobe"), "breachdate": .string("2013-10-04")], edgeLabel: "FOUND_IN_BREACH"),
            .init(
                enricher: .usernameToMaigret, inputType: .username, inputValue: "anna_k", outputType: .socialAccount,
                outputValue: "github:anna_k",
                properties: ["platform": .string("github"), "profile_url": .string("https://github.com/anna_k")], edgeLabel: "HAS_ACCOUNT"),
            .init(
                enricher: .usernameToMaigret, inputType: .username, inputValue: "anna_k", outputType: .socialAccount,
                outputValue: "twitter:anna_k",
                properties: ["platform": .string("twitter"), "profile_url": .string("https://x.com/anna_k")],
                edgeLabel: "HAS_ACCOUNT"),
            .init(
                enricher: .phoneToInfos, inputType: .phone, inputValue: "+79990000000", outputType: .phone, outputValue: "+79990000000",
                properties: ["country": .string("RU"), "carrier": .string("МТС"), "line_type": .string("mobile")], edgeLabel: "SAME"),
        ]
    }

    private func harness(scanTimeout: Duration = .seconds(10)) async throws -> OSINTServiceHarness {
        let harness = try await OSINTServiceHarness(database: try osintDatabase(), findings: Self.findings(), scanTimeout: scanTimeout)
        harnesses.append(harness)
        try await harness.installed()
        return harness
    }

    private func anna(_ h: OSINTServiceHarness) throws -> UUID {
        try h.persons.createPerson(
            draft: .init(displayName: "Анна Каренина", phones: ["+7 999 000-00-00"], emails: [Self.anna], usernames: ["anna_k"]))
    }

    func testInputsComeFromCurrentValuesOnly() async throws {
        let h = try await harness()
        let id = try anna(h)
        try h.persons.addNote(contactID: id, text: "секретная заметка")
        try h.persons.removeValue(personID: id, field: .usernames, value: "anna_k", reason: .removedByUser)
        try h.persons.addProposedObservations(
            personID: id,
            [
                Observation(
                    field: "emails", value: "other@example.test",
                    source: SourceStamp(identity: OSINTGraphMapping.identity(serverID: UUID(), sketchID: "x")), status: .proposed)
            ])
        let inputs = try await h.service.inputs(personID: id)
        XCTAssertEqual(
            inputs,
            [
                OSINTInput(type: .email, value: Self.anna), OSINTInput(type: .phone, value: "+79990000000"),
                OSINTInput(type: .individual, value: "Анна Каренина"),
            ])
    }

    func testEnrichBeforeInstallIsNotInstalled() async throws {
        let harness = try await OSINTServiceHarness(database: try osintDatabase())
        harnesses.append(harness)
        try await harness.configure()
        try await harness.trust()
        let id = try anna(harness)
        do {
            _ = try await harness.service.enrich(
                personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
            XCTFail("not installed")
        } catch { XCTAssertEqual(error as? OSINTFailure, .notInstalled, "\(error)") }
    }

    func testManualRunCreatesSketchNodesLaunchesAndProposes() async throws {
        let h = try await harness()
        let id = try anna(h)
        let inputs = try await h.service.inputs(personID: id)
        let runID = try await h.service.enrich(personID: id, enrichers: OSINTEnricher.manualDefault, inputs: inputs)
        await h.service.settled()
        let runValue = try await h.store.run(id: runID)
        let run = try XCTUnwrap(runValue)
        XCTAssertEqual(run.state, .completed, "\(run)")
        XCTAssertEqual(run.found, 4, "avatar, two social accounts and the phone carrier; breaches need a key")
        let attempts = try await h.store.attempts(runID: runID)
        XCTAssertEqual(attempts.filter { $0.kind == .createSketch }.count, 1)
        XCTAssertEqual(attempts.filter { $0.kind == .addNode }.count, 4, "email, phone, username, individual")
        let launches = attempts.filter { $0.kind == .launch }
        XCTAssertEqual(
            Set(launches.compactMap(\.payload.enricher)),
            [.emailToGravatar, .emailToHudsonRock, .phoneToInfos, .usernameToMaigret, .individualToUsernameCandidates],
            "every compatible keyless enricher once")
        XCTAssertTrue(attempts.allSatisfy { $0.state == .confirmed }, "\(attempts.map(\.state))")
        let person = try XCTUnwrap(try h.persons.person(id: id))
        let proposed = person.observations.filter { $0.status == .proposed }
        XCTAssertEqual(Set(proposed.map(\.field)), ["avatar", "social.github", "social.twitter", "phone.info"])
        let link = try await h.store.sketch(personID: id)
        XCTAssertNotNil(link)
        let serverID = try await h.store.settings().serverID
        XCTAssertTrue(person.identities.contains(OSINTGraphMapping.identity(serverID: serverID, sketchID: link!.sketchID)))
        XCTAssertEqual(run.found, proposed.count)
    }

    func testSecondRunReusesSketchAndNodes() async throws {
        let h = try await harness()
        let id = try anna(h)
        _ = try await h.service.enrich(personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        try h.persons.updatePerson(
            id: id,
            draft: .init(
                displayName: "Анна Каренина", phones: ["+79990000000", "+79990000001"], emails: [Self.anna], usernames: ["anna_k"]))
        let second = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar, .phoneToInfos],
            inputs: [OSINTInput(type: .email, value: Self.anna), OSINTInput(type: .phone, value: "+79990000001")])
        await h.service.settled()
        let attempts = try await h.store.attempts(runID: second)
        XCTAssertTrue(attempts.filter { $0.kind == .createSketch }.isEmpty, "the sketch exists")
        XCTAssertEqual(attempts.filter { $0.kind == .addNode }.count, 1, "only the new phone")
        let investigationID = try await h.store.settings().investigationID!
        let sketches = try await h.api.sketches(investigationID: investigationID)
        XCTAssertEqual(sketches.count, 1)
        let graph = try await h.api.graph(sketchID: sketches[0].id)
        XCTAssertEqual(graph.nodes.filter { $0.type == "Email" }.count, 1)
    }

    func testKeyedEnricherSkippedWithoutKey() async throws {
        let h = try await harness()
        let id = try anna(h)
        let first = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar, .emailToBreaches], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let firstAttempts = try await h.store.attempts(runID: first)
        let withoutKey = firstAttempts.filter { $0.kind == .launch }.compactMap(\.payload.enricher)
        XCTAssertEqual(withoutKey, [.emailToGravatar])
        _ = try await h.api.createKey(name: "HIBP_API_KEY", value: "k")
        let second = try await h.service.enrich(
            personID: id, enrichers: [.emailToBreaches], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let secondAttempts = try await h.store.attempts(runID: second)
        let withKey = secondAttempts.filter { $0.kind == .launch }.compactMap(\.payload.enricher)
        XCTAssertEqual(withKey, [.emailToBreaches])
        let person = try XCTUnwrap(try h.persons.person(id: id))
        XCTAssertTrue(person.observations.contains { $0.field == "breach" && $0.value == "Adobe, 2013-10-04" })
    }

    func testFailedScanRejectsAttemptRunCompletes() async throws {
        let h = try await harness()
        let id = try anna(h)
        await h.api.failNext(.apiRejected(code: 500, stage: "scan"), stage: "scan")
        let runID = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let runValue = try await h.store.run(id: runID)
        let run = try XCTUnwrap(runValue)
        XCTAssertEqual(run.state, .completed)
        let launchValue = try await h.store.attempts(runID: runID).first { $0.kind == .launch }
        let launch = try XCTUnwrap(launchValue)
        XCTAssertEqual(launch.state, .rejected)
        XCTAssertEqual(launch.failure, .apiRejected(code: 500, stage: "scan"))
    }

    func testHungScanTimesOutToUnknown() async throws {
        let h = try await harness(scanTimeout: .milliseconds(300))
        let id = try anna(h)
        await h.api.hangNextLaunch()
        let runID = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let runValue = try await h.store.run(id: runID)
        let run = try XCTUnwrap(runValue)
        XCTAssertEqual(run.state, .unknown)
        let attempts = try await h.store.attempts(runID: runID)
        let launch = try XCTUnwrap(attempts.first { $0.kind == .launch })
        XCTAssertEqual(launch.state, .unknown)
        XCTAssertEqual(launch.failure, .unknownOutcome(stage: "scan"))
        XCTAssertNotNil(launch.response?.scanID, "the task id stays for a later check")
        let launches = await h.api.recordedLaunches
        XCTAssertEqual(launches.count, 1, "no second launch")
    }

    func testUnknownOutcomeOnAddNodeKeepsGoing() async throws {
        let h = try await harness()
        let id = try anna(h)
        await h.api.failNext(.unknownOutcome(stage: "addNode"), stage: "addNode")
        let runID = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar, .usernameToMaigret],
            inputs: [OSINTInput(type: .email, value: Self.anna), OSINTInput(type: .username, value: "anna_k")])
        await h.service.settled()
        let attempts = try await h.store.attempts(runID: runID)
        let nodes = attempts.filter { $0.kind == .addNode }
        XCTAssertEqual(nodes.map(\.state).sorted { $0.rawValue < $1.rawValue }, [.confirmed, .unknown])
        XCTAssertEqual(attempts.filter { $0.kind == .launch }.count, 1, "the username still ran")
        let runValue = try await h.store.run(id: runID)
        let run = try XCTUnwrap(runValue)
        XCTAssertEqual(run.state, .unknown, "an open attempt keeps the run open")
    }

    func testManualRunsPrecedeBookRuns() async throws {
        let h = try await harness()
        let anna = try anna(h)
        let boris = try h.persons.createPerson(draft: .init(displayName: "Борис", emails: ["boris@example.test"]))
        let viktor = try h.persons.createPerson(draft: .init(displayName: "Виктор", emails: ["viktor@example.test"]))
        let book = ImportSource(service: "carddav", accountID: "acc")
        // The first run starts at once; the two queued behind it are taken manual-first.
        _ = try await h.service.enrich(
            personID: boris, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: "boris@example.test")],
            trigger: .book(book))
        let second = try await h.service.enrich(
            personID: viktor, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: "viktor@example.test")],
            trigger: .book(book))
        let third = try await h.service.enrich(
            personID: anna, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let runs = try await h.store.runs(open: false)
        let manual = try XCTUnwrap(runs.first { $0.id == third })
        let automatic = try XCTUnwrap(runs.first { $0.id == second })
        XCTAssertEqual(manual.state, .completed)
        XCTAssertEqual(automatic.state, .completed)
        XCTAssertTrue(manual.startedAt! <= automatic.startedAt!, "the manual run went before the automatic one queued earlier")
    }

    func testLimitTruncatesTo200AndFlags() async throws {
        var findings: [FlowsintSynthetic.Finding] = []
        for index in 0..<205 {
            findings.append(
                .init(
                    enricher: .individualToUsernameCandidates, inputType: .individual, inputValue: "Анна Каренина", outputType: .username,
                    outputValue: "anna_\(index)"))
        }
        let h = try await OSINTServiceHarness(database: try osintDatabase(), findings: findings)
        harnesses.append(h)
        try await h.installed()
        let id = try anna(h)
        let runID = try await h.service.enrich(
            personID: id, enrichers: [.individualToUsernameCandidates], inputs: [OSINTInput(type: .individual, value: "Анна Каренина")])
        await h.service.settled()
        let runValue = try await h.store.run(id: runID)
        let run = try XCTUnwrap(runValue)
        XCTAssertEqual(run.found, 200)
        XCTAssertTrue(run.truncated)
        let person = try XCTUnwrap(try h.persons.person(id: id))
        XCTAssertEqual(person.observations.filter { $0.status == .proposed }.count, 200)
    }

    func testNoRawValuesInRunOrAttemptRows() async throws {
        let h = try await harness()
        let id = try anna(h)
        let inputs = try await h.service.inputs(personID: id)
        _ = try await h.service.enrich(personID: id, enrichers: OSINTEnricher.manualDefault, inputs: inputs)
        await h.service.settled()
        for table in ["persons_osint_runs", "persons_osint_attempts"] {
            let text = try h.db.execute("SELECT data::text FROM \(table)").joined().joined()
            XCTAssertFalse(text.contains(Self.anna), table)
            XCTAssertFalse(text.contains("79990000000"), table)
            XCTAssertFalse(text.contains("anna_k"), table)
            XCTAssertFalse(text.contains("Каренина"), table)
        }
    }

    func testForeignNodesInSketchAreNotInputs() async throws {
        let stranger = FlowsintSynthetic.Finding(
            enricher: .emailToGravatar, inputType: .email, inputValue: "stranger@example.test", outputType: .gravatar,
            outputValue: "hash-stranger",
            properties: ["src": .string("https://www.gravatar.com/avatar/hash-stranger"), "exists": .bool(true)],
            edgeLabel: "HAS_GRAVATAR")
        let h = try await OSINTServiceHarness(
            database: try osintDatabase(), findings: Self.findings() + [stranger], scanTimeout: .seconds(10))
        harnesses.append(h)
        try await h.installed()
        let id = try anna(h)
        _ = try await h.service.enrich(
            personID: id, enrichers: [.usernameToMaigret], inputs: [OSINTInput(type: .username, value: "anna_k")])
        await h.service.settled()
        let sketchLink = try await h.store.sketch(personID: id)
        let sketch = try XCTUnwrap(sketchLink)
        // The user grows the sketch in flowsint's own interface: a stranger's address and its avatar.
        let node = try await h.api.addNode(sketchID: sketch.sketchID, type: .email, value: "stranger@example.test")
        _ = try await h.api.launch(enricher: .emailToGravatar, sketchID: sketch.sketchID, nodeIDs: [node])
        _ = try await h.api.graph(sketchID: sketch.sketchID)
        _ = try await h.service.enrich(
            personID: id, enrichers: [.usernameToMaigret], inputs: [OSINTInput(type: .username, value: "anna_k")])
        await h.service.settled()
        let person = try XCTUnwrap(h.persons.person(id: id))
        XCTAssertFalse(person.observations.contains { $0.field == "avatar" }, "a node nobody linked to Anna's inputs is not hers")
        XCTAssertTrue(person.observations.contains { $0.field == "social.github" })
    }

    func testRunSkipsEnrichersTheServerLacks() async throws {
        let h = try await harness()
        await h.api.setOfferedEnrichers(Set(OSINTEnricher.allCases.map(\.rawValue)).subtracting(["phone_to_infos"]))
        let id = try anna(h)
        let inputs = [OSINTInput(type: .email, value: Self.anna), OSINTInput(type: .phone, value: "+79990000000")]
        let runID = try await h.service.enrich(personID: id, enrichers: [.emailToGravatar, .phoneToInfos], inputs: inputs)
        await h.service.settled()
        let run = try await h.store.run(id: runID)
        XCTAssertEqual(run?.state, .completed, "\(run?.failure?.code ?? "")")
        let launched = try await h.store.attempts(runID: runID).filter { $0.kind == .launch }.compactMap { $0.payload.enricher }
        XCTAssertEqual(launched, [.emailToGravatar], "no launch for a source the server does not offer")
        let onlyMissing = try await h.service.enrich(personID: id, enrichers: [.phoneToInfos], inputs: inputs)
        await h.service.settled()
        let failed = try await h.store.run(id: onlyMissing)
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.failure, .enricherUnavailable("phone_to_infos"))
        let snapshot = try await h.service.snapshot()
        XCTAssertEqual(snapshot.serverEnricherNames?.contains("phone_to_infos"), false)
    }
}

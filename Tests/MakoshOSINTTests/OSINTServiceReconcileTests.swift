import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

final class OSINTServiceReconcileTests: XCTestCase {
    private var harnesses: [OSINTServiceHarness] = []
    static let anna = OSINTServiceRunTests.anna
    private let book = ImportSource(service: "carddav", accountID: "acc")

    override func tearDown() async throws {
        for harness in harnesses { await harness.stop() }
        harnesses = []
    }

    private func harness(scanTimeout: Duration = .seconds(10), clock: Box<Date>? = nil) async throws -> OSINTServiceHarness {
        let now: @Sendable () -> Date = clock.map { box in { @Sendable in box.value } } ?? { @Sendable in Date() }
        let harness = try await OSINTServiceHarness(
            database: try osintDatabase(), findings: OSINTServiceRunTests.findings(), scanTimeout: scanTimeout, now: now)
        harnesses.append(harness)
        try await harness.installed()
        return harness
    }

    private func anna(_ h: OSINTServiceHarness) throws -> UUID {
        try h.persons.createPerson(
            draft: .init(displayName: "Анна Каренина", phones: ["+79990000000"], emails: [Self.anna], usernames: ["anna_k"]))
    }

    private func bookPerson(
        _ h: OSINTServiceHarness, _ name: String, email: String, source: ImportSource? = nil, kind: PersonKind? = nil
    ) throws -> UUID {
        try h.persons.linkImportedPerson(
            .init(externalID: email, displayName: name, kind: kind, emails: [email]), source: source ?? book, fetchedAt: Date(),
            contactID: nil)
    }

    private func openAttempts(_ h: OSINTServiceHarness, _ runID: UUID) async throws -> [OSINTAttempt] {
        try await h.store.attempts(runID: runID).filter { $0.state.isOpen }
    }

    func testUnknownLaunchIsConfirmedByGraphRead() async throws {
        let h = try await harness()
        let id = try anna(h)
        await h.api.failNext(.unknownOutcome(stage: "launch"), stage: "launch")
        let runID = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        var attempts = try await h.store.attempts(runID: runID)
        XCTAssertEqual(attempts.first { $0.kind == .launch }?.state, .unknown)
        var launches = await h.api.recordedLaunches
        XCTAssertEqual(launches.count, 1)
        await h.service.reconcile(autoSources: [])
        attempts = try await h.store.attempts(runID: runID)
        XCTAssertEqual(attempts.first { $0.kind == .launch }?.state, .confirmed, "the graph shows the gravatar the launch produced")
        let runValue = try await h.store.run(id: runID)
        XCTAssertEqual(runValue?.state, .completed)
        let person = try XCTUnwrap(try h.persons.person(id: id))
        XCTAssertTrue(person.observations.contains { $0.field == "avatar" && $0.status == .proposed })
        launches = await h.api.recordedLaunches
        XCTAssertEqual(launches.count, 1, "settling never launches again")
    }

    func testUnknownCreateSketchFoundByTitle() async throws {
        let h = try await harness()
        let id = try anna(h)
        await h.api.failNext(.unknownOutcome(stage: "createSketch"), stage: "createSketch")
        let runID = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let runBefore = try await h.store.run(id: runID)
        XCTAssertEqual(runBefore?.state, .unknown)
        let linkBefore = try await h.store.sketch(personID: id)
        XCTAssertNil(linkBefore)
        await h.service.reconcile(autoSources: [])
        let attempts = try await h.store.attempts(runID: runID)
        XCTAssertEqual(attempts.first { $0.kind == .createSketch }?.state, .confirmed)
        let link = try await h.store.sketch(personID: id)
        XCTAssertNotNil(link)
        let investigationID = try await h.store.settings().investigationID!
        let sketches = try await h.api.sketches(investigationID: investigationID)
        XCTAssertEqual(sketches.count, 1, "the sketch the server created once is adopted, not duplicated")
        let runAfter = try await h.store.run(id: runID)
        XCTAssertEqual(runAfter?.state, .completed)
    }

    func testUnknownAddNodeWithoutHMACStaysUnknown() async throws {
        let h = try await harness()
        let id = try anna(h)
        await h.api.failNext(.unknownOutcome(stage: "addNode"), stage: "addNode")
        let runID = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        try await h.vault.removeAll()
        await h.service.reconcile(autoSources: [])
        let attempts = try await h.store.attempts(runID: runID)
        XCTAssertEqual(attempts.first { $0.kind == .addNode }?.state, .unknown, "without the journal key the node cannot be matched")
        try await h.vault.ensureHMACKey()
    }

    func testDismissRejectsAndFailsRun() async throws {
        let h = try await harness(scanTimeout: .milliseconds(200))
        let id = try anna(h)
        await h.api.hangNextLaunch()
        let service = h.service
        let runID = try await service.enrich(
            personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await service.settled()
        let open = try await openAttempts(h, runID)
        XCTAssertEqual(open.count, 1)
        try await service.dismiss(attemptID: open[0].id)
        let attempts = try await h.store.attempts(runID: runID)
        XCTAssertEqual(attempts.first { $0.id == open[0].id }?.state, .rejected)
        let run = try await h.store.run(id: runID)
        XCTAssertEqual(run?.state, .failed)
        XCTAssertEqual(run?.failure, .unknownOutcome(stage: "run"))
    }

    func testRestartMidRunSettlesWithoutDuplicates() async throws {
        let h = try await harness()
        let id = try anna(h)
        let investigationID = try await h.store.settings().investigationID!
        // The server created the sketch; Makosh died before recording the answer.
        _ = try await h.api.createSketch(title: id.uuidString, investigationID: investigationID)
        var run = OSINTRun(personID: id, trigger: .manual, enrichers: [.emailToGravatar])
        try await h.store.saveRun(run)
        run.state = .running
        try await h.store.saveRun(run)
        var attempt = OSINTAttempt(runID: run.id, personID: id, kind: .createSketch, payload: OSINTAttemptPayload())
        try await h.store.saveAttempt(attempt)
        attempt.state = .sent
        try await h.store.saveAttempt(attempt)
        let api = h.api
        let second = OSINTService(
            persons: h.persons, store: h.store, vault: h.vault,
            sessionFactory: { settings, password in
                OSINTSSHSession(
                    host: settings.host, port: settings.port, login: settings.login, password: password,
                    expectedFingerprint: settings.hostKeyFingerprint)
            }, apiFactory: { _, _, _ in api })
        try await second.open()
        let afterOpen = try await h.store.attempt(id: attempt.id)
        XCTAssertEqual(afterOpen?.state, .unknown)
        await second.reconcile(autoSources: [])
        let settled = try await h.store.attempt(id: attempt.id)
        XCTAssertEqual(settled?.state, .confirmed)
        let sketches = try await h.api.sketches(investigationID: investigationID)
        XCTAssertEqual(sketches.count, 1)
        let link = try await h.store.sketch(personID: id)
        XCTAssertEqual(link?.sketchID, sketches.first?.id)
        await second.close()
    }

    func testDeletedPersonGetsNoObservationsAndLosesSketch() async throws {
        let h = try await harness(scanTimeout: .milliseconds(300))
        let id = try anna(h)
        await h.api.hangNextLaunch()
        let runID = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        try h.persons.deletePerson(id: id)
        await h.service.settled()
        let person = try XCTUnwrap(try h.persons.person(id: id))
        XCTAssertTrue(person.observations.filter { $0.status == .proposed }.isEmpty, "a deleted person gets no proposals")
        _ = runID
        await h.service.reconcile(autoSources: [])
        let link = try await h.store.sketch(personID: id)
        XCTAssertNotNil(link?.deletedAt)
        let remote = try await h.api.sketch(id: link!.sketchID)
        XCTAssertNil(remote)
        let deletions = try await h.store.attempts(open: false).filter { $0.kind == .deleteSketch }
        XCTAssertEqual(deletions.map(\.state), [.confirmed])
    }

    func testMergedPersonSketchIsDeleted() async throws {
        let h = try await harness()
        let anna = try anna(h)
        let boris = try h.persons.createPerson(draft: .init(displayName: "Борис", emails: ["boris@example.test"]))
        _ = try await h.service.enrich(personID: anna, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        _ = try await h.service.enrich(
            personID: boris, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: "boris@example.test")])
        await h.service.settled()
        _ = try h.persons.merge(survivorID: anna, removedID: boris)
        await h.service.reconcile(autoSources: [])
        let annaLink = try await h.store.sketch(personID: anna)
        XCTAssertNil(annaLink?.deletedAt, "the survivor keeps its sketch")
        let borisLink = try await h.store.sketch(personID: boris)
        XCTAssertNotNil(borisLink?.deletedAt)
        let investigationID = try await h.store.settings().investigationID!
        let sketches = try await h.api.sketches(investigationID: investigationID)
        XCTAssertEqual(sketches.map(\.id), [annaLink!.sketchID])
    }

    func testReconcileQueuesOnlyBookPeople() async throws {
        let h = try await harness()
        let person = try bookPerson(h, "Иван", email: "ivan@example.test")
        _ = try bookPerson(h, "ООО Ромашка", email: "office@romashka.test", kind: .organization)
        _ = try bookPerson(h, "Письмо", email: "letter@example.test", source: ImportSource(service: "mail", accountID: "acc"))
        await h.service.reconcile(autoSources: [book])
        await h.service.settled()
        let runs = try await h.store.runs(open: false)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.personID, person)
        XCTAssertEqual(runs.first?.trigger, .book(book))
        XCTAssertEqual(runs.first?.enrichers, OSINTEnricher.automaticDefault)
        XCTAssertFalse(runs.first!.enrichers.contains(.orgToDomains))
        await h.service.reconcile(autoSources: [book])
        await h.service.settled()
        let again = try await h.store.runs(open: false)
        XCTAssertEqual(again.count, 1, "a person with a sketch is not enriched again")
    }

    func testReconcileRespectsHourlyLimit() async throws {
        let clock = Box<Date>(Date(timeIntervalSince1970: 1_800_000_000))
        let h = try await harness(clock: clock)
        var settings = try await h.service.settings()
        settings.automaticRunsPerHour = 2
        try await h.service.saveSettings(settings)
        for index in 0..<5 { _ = try bookPerson(h, "Персона \(index)", email: "p\(index)@example.test") }
        await h.service.reconcile(autoSources: [book])
        await h.service.settled()
        var runs = try await h.store.runs(open: false)
        XCTAssertEqual(runs.count, 2)
        await h.service.reconcile(autoSources: [book])
        await h.service.settled()
        runs = try await h.store.runs(open: false)
        XCTAssertEqual(runs.count, 2, "the hour is not over")
        clock.value = clock.value.addingTimeInterval(3601)
        await h.service.reconcile(autoSources: [book])
        await h.service.settled()
        runs = try await h.store.runs(open: false)
        XCTAssertEqual(runs.count, 4)
    }

    func testReconcileSkipsPersonsWithRecentRun() async throws {
        let h = try await harness()
        let person = try bookPerson(h, "Иван", email: "ivan@example.test")
        // A failed run without a sketch is still a recent run.
        var run = OSINTRun(personID: person, trigger: .book(book), enrichers: OSINTEnricher.automaticDefault)
        try await h.store.saveRun(run)
        run.state = .failed
        run.failure = .unknownOutcome(stage: "connect")
        try await h.store.saveRun(run)
        await h.service.reconcile(autoSources: [book])
        await h.service.settled()
        let runs = try await h.store.runs(open: false)
        XCTAssertEqual(runs.count, 1)
    }

    func testReconcileCancelsQueuedRunsOfUnflaggedBooks() async throws {
        let h = try await harness()
        let person = try bookPerson(h, "Иван", email: "ivan@example.test")
        let run = OSINTRun(personID: person, trigger: .book(book), enrichers: OSINTEnricher.automaticDefault)
        try await h.store.saveRun(run)
        await h.service.reconcile(autoSources: [])
        await h.service.settled()
        let after = try await h.store.run(id: run.id)
        XCTAssertEqual(after?.state, .failed)
        XCTAssertEqual(after?.failure, .disabled)
    }

    func testDeleteOSINTDataRemovesProposedKeepsConfirmed() async throws {
        let h = try await harness()
        let id = try anna(h)
        _ = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar, .usernameToMaigret],
            inputs: [OSINTInput(type: .email, value: Self.anna), OSINTInput(type: .username, value: "anna_k")])
        await h.service.settled()
        var person = try XCTUnwrap(try h.persons.person(id: id))
        let avatar = try XCTUnwrap(person.observations.first { $0.field == "avatar" })
        XCTAssertEqual(try h.persons.acceptObservation(personID: id, observationID: avatar.id), .applied)
        try await h.service.deleteOSINTData(personID: id)
        person = try XCTUnwrap(try h.persons.person(id: id))
        XCTAssertEqual(person.observations.filter { $0.source.identity.service == "osint" }.map(\.field), ["avatar"])
        let link = try await h.store.sketch(personID: id)
        XCTAssertNotNil(link?.deletedAt)
        let remote = try await h.api.sketch(id: link!.sketchID)
        XCTAssertNil(remote)
    }
}

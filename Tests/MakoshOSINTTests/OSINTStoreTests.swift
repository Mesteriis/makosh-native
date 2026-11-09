import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

final class OSINTStoreTests: XCTestCase {
    func testOpenCreatesTablesAndMeta() async throws {
        let db = try osintDatabase()
        _ = try await osintStore(db)
        let tables = try db.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema='\(db.schema)' AND table_name LIKE 'persons_osint_%' ORDER BY 1"
        )
        XCTAssertEqual(
            tables.map { $0[0] },
            [
                "persons_osint_attempts", "persons_osint_installs", "persons_osint_meta", "persons_osint_runs", "persons_osint_settings",
                "persons_osint_sketches",
            ])
        XCTAssertEqual(try db.execute("SELECT version::text FROM persons_osint_meta WHERE id=1"), [["1"]])
    }

    func testSettingsDefaultsAndRoundTrip() async throws {
        let store = try await osintStore(try osintDatabase())
        var settings = try await store.settings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.port, 22)
        XCTAssertEqual(settings.serviceEmail, "makosh-osint@sh-inc.dev")
        XCTAssertEqual(settings.manualEnrichers, OSINTEnricher.manualDefault)
        XCTAssertEqual(settings.automaticEnrichers, OSINTEnricher.automaticDefault)
        XCTAssertEqual(settings.automaticRunsPerHour, 20)
        XCTAssertTrue(settings.envBackupAvailable)
        XCTAssertFalse(OSINTEnricher.manualDefault.contains(.emailToBreaches), "keyed enrichers are not in the manual default")
        XCTAssertEqual(
            OSINTEnricher.automaticDefault, [.emailToGravatar, .emailToHudsonRock, .phoneToInfos, .individualToUsernameCandidates])
        settings.enabled = true
        settings.host = "10.34.10.64"
        settings.login = "makosh"
        settings.hostKeyFingerprint = "SHA256:abc"
        settings.installedTag = "v1.2.13"
        settings.automaticEnrichers.insert(.usernameToMaigret)
        try await store.saveSettings(settings)
        let read = try await store.settings()
        XCTAssertEqual(read, settings)
        XCTAssertEqual(read.serverID, settings.serverID, "the server id is generated once and then persisted")
    }

    func testAttemptTransitionsAreRestricted() async throws {
        let store = try await osintStore(try osintDatabase())
        var attempt = OSINTAttempt(kind: .createSketch, payload: OSINTAttemptPayload())
        try await store.saveAttempt(attempt)
        attempt.state = .confirmed
        do {
            try await store.saveAttempt(attempt)
            XCTFail("queued cannot jump to confirmed")
        } catch { XCTAssertEqual(error as? OSINTFailure, .storage("attempt transition"), "\(error)") }
        XCTAssertTrue(OSINTAttempt.allows(.queued, .sent))
        XCTAssertTrue(OSINTAttempt.allows(.sent, .unknown))
        XCTAssertTrue(OSINTAttempt.allows(.unknown, .confirmed))
        XCTAssertTrue(OSINTAttempt.allows(.queued, .rejected))
        XCTAssertFalse(OSINTAttempt.allows(.confirmed, .unknown))
        XCTAssertFalse(OSINTAttempt.allows(.unknown, .sent))
        let fresh = OSINTAttempt(kind: .launch, state: .sent, payload: OSINTAttemptPayload())
        do {
            try await store.saveAttempt(fresh)
            XCTFail("a new attempt starts queued")
        } catch { XCTAssertEqual(error as? OSINTFailure, .storage("attempt transition"), "\(error)") }
    }

    func testSentBecomesUnknownOnOpen() async throws {
        let db = try osintDatabase()
        let store = try await osintStore(db)
        let person = UUID()
        var run = OSINTRun(personID: person, trigger: .manual, enrichers: [.emailToGravatar])
        try await store.saveRun(run)
        run.state = .running
        try await store.saveRun(run)
        var attempt = OSINTAttempt(runID: run.id, personID: person, kind: .launch, payload: OSINTAttemptPayload(enricher: .emailToGravatar))
        try await store.saveAttempt(attempt)
        attempt.state = .sent
        try await store.saveAttempt(attempt)
        try await store.markSentAsUnknownOnOpen()
        let reread = try await store.attempt(id: attempt.id)
        XCTAssertEqual(reread?.state, .unknown)
        XCTAssertEqual(reread?.failure, .unknownOutcome(stage: "restart"))
        let rerunRun = try await store.run(id: run.id)
        XCTAssertEqual(rerunRun?.state, .unknown)
        let openAttempts = try await store.attempts(open: true)
        XCTAssertEqual(openAttempts.map(\.id), [attempt.id])
        let openRuns = try await store.runs(open: true)
        XCTAssertEqual(openRuns.map(\.id), [run.id])
    }

    func testAttemptPayloadNeverStoresRawValues() async throws {
        let db = try osintDatabase()
        let store = try await osintStore(db)
        let attempt = OSINTAttempt(
            kind: .addNode, payload: OSINTAttemptPayload(sketchID: "sk-1", nodeType: .email, valueHMAC: "abc"))
        try await store.saveAttempt(attempt)
        let rows = try db.execute("SELECT data::text FROM persons_osint_attempts")
        XCTAssertEqual(rows.count, 1)
        let text = rows[0][0]
        XCTAssertTrue(text.contains("valueHMAC") && text.contains("\"abc\""), text)
        XCTAssertFalse(text.contains("anna@example.test"))
        XCTAssertFalse(text.contains("+79990000000"))
        let payload = OSINTAttemptPayload(sketchID: "sk-1", nodeType: .phone, valueHMAC: nil)
        let mirror = String(reflecting: payload)
        XCTAssertFalse(mirror.contains("value:"), "the payload has no field that could carry a raw value")
    }

    func testAutomaticRunCountSinceCountsOnlyBookTriggers() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try await osintStore(try osintDatabase(), now: { base })
        let source = ImportSource(service: "carddav", accountID: "acc")
        for offset: TimeInterval in [-600, -300] {
            let run = OSINTRun(
                personID: UUID(), trigger: .book(source), enrichers: [.emailToGravatar], createdAt: base.addingTimeInterval(offset))
            try await store.saveRun(run)
        }
        try await store.saveRun(
            OSINTRun(personID: UUID(), trigger: .manual, enrichers: [.emailToGravatar], createdAt: base.addingTimeInterval(-100)))
        try await store.saveRun(
            OSINTRun(personID: UUID(), trigger: .book(source), enrichers: [.emailToGravatar], createdAt: base.addingTimeInterval(-7200)))
        let count = try await store.automaticRunCount(since: base.addingTimeInterval(-3600))
        XCTAssertEqual(count, 2)
        XCTAssertEqual(OSINTRunTrigger.book(source).key, "book:carddav/acc")
        XCTAssertEqual(OSINTRunTrigger.manual.key, "manual")
    }

    func testLastRunPerPerson() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try await osintStore(try osintDatabase(), now: { base })
        let anna = UUID(), boris = UUID()
        let first = OSINTRun(personID: anna, trigger: .manual, enrichers: [.emailToGravatar], createdAt: base.addingTimeInterval(-200))
        let second = OSINTRun(personID: anna, trigger: .manual, enrichers: [.phoneToInfos], createdAt: base.addingTimeInterval(-100))
        try await store.saveRun(first)
        try await store.saveRun(second)
        try await store.saveRun(OSINTRun(personID: boris, trigger: .manual, enrichers: [.emailToGravatar], createdAt: base))
        let last = try await store.lastRun(personID: anna)
        XCTAssertEqual(last?.id, second.id)
        let none = try await store.lastRun(personID: UUID())
        XCTAssertNil(none)
        let empty = try await store.attempts(runID: first.id)
        XCTAssertEqual(empty, [])
    }

    func testSketchLinkAndInstallRoundTrip() async throws {
        let store = try await osintStore(try osintDatabase())
        let person = UUID()
        var link = OSINTSketchLink(personID: person, sketchID: "sk-1", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.saveSketch(link)
        let stored = try await store.sketch(personID: person)
        XCTAssertEqual(stored, link)
        link.deletedAt = Date(timeIntervalSince1970: 1_800_000_100)
        try await store.saveSketch(link)
        let all = try await store.sketches()
        XCTAssertEqual(all, [link])
        var install = OSINTInstall(targetTag: "v1.2.13", targetSHA: "4c05849b", createdAt: Date(timeIntervalSince1970: 1_800_000_200.25))
        install.steps = OSINTInstallStepKind.allCases.map { OSINTInstallStep(kind: $0, state: .pending) }
        try await store.saveInstall(install)
        install.state = .completed
        install.steps[0].state = .skipped
        try await store.saveInstall(install)
        let installs = try await store.installs()
        XCTAssertEqual(installs, [install])
    }
}

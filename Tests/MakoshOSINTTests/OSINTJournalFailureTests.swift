import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

/// Every flowsint write is one journaled attempt: when the journal row cannot be saved, nothing is sent.
final class OSINTJournalFailureTests: XCTestCase {
    private var harnesses: [OSINTServiceHarness] = []
    static let anna = OSINTServiceRunTests.anna

    override func tearDown() async throws {
        for harness in harnesses { await harness.stop() }
        harnesses = []
    }

    private func harness() async throws -> OSINTServiceHarness {
        let harness = try await OSINTServiceHarness(database: try osintDatabase(), findings: OSINTServiceRunTests.findings())
        harnesses.append(harness)
        try await harness.installed()
        return harness
    }

    private func anna(_ h: OSINTServiceHarness) throws -> UUID {
        try h.persons.createPerson(draft: .init(displayName: "Анна Каренина", emails: [Self.anna], usernames: ["anna_k"]))
    }

    /// PostgreSQL refuses every new attempt row from now on; existing rows stay.
    private func breakJournal(_ h: OSINTServiceHarness) throws {
        try h.db.execute("ALTER TABLE persons_osint_attempts ADD CONSTRAINT no_attempts CHECK (false) NOT VALID")
    }

    private func isStorage(_ failure: OSINTFailure?) -> Bool {
        if case .storage = failure { return true }
        return false
    }

    func testSketchJournalFailureSendsNothingAndFailsTheRun() async throws {
        let h = try await harness()
        let id = try anna(h)
        try breakJournal(h)
        _ = try await h.service.enrich(personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let run = try await h.service.lastRun(personID: id)
        XCTAssertEqual(run?.state, .failed)
        XCTAssertTrue(isStorage(run?.failure), "\(String(describing: run?.failure))")
        let settings = try await h.service.settings()
        let investigation = try XCTUnwrap(settings.investigationID)
        let sketches = try await h.api.sketches(investigationID: investigation)
        XCTAssertTrue(sketches.isEmpty, "no sketch without its journal row")
        let launches = await h.api.recordedLaunches
        XCTAssertTrue(launches.isEmpty)
    }

    func testLaunchJournalFailureSendsNothingAndFailsTheRun() async throws {
        let h = try await harness()
        let id = try anna(h)
        _ = try await h.service.enrich(personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let firstRun = try await h.service.lastRun(personID: id)
        XCTAssertEqual(firstRun?.state, .completed)
        let before = await h.api.recordedLaunches.count
        XCTAssertEqual(before, 1)
        try breakJournal(h)
        // The sketch and the node exist: the first new write of this run is the launch.
        _ = try await h.service.enrich(personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let run = try await h.service.lastRun(personID: id)
        XCTAssertEqual(run?.state, .failed)
        XCTAssertTrue(isStorage(run?.failure), "\(String(describing: run?.failure))")
        let after = await h.api.recordedLaunches.count
        XCTAssertEqual(after, before, "no launch without its journal row")
    }

    func testKeyJournalFailureNeverReachesTheServer() async throws {
        let h = try await harness()
        try breakJournal(h)
        do {
            try await h.service.setKey(name: "HIBP_API_KEY", value: "hibp-secret-value")
            XCTFail("the storage failure reaches the user")
        } catch {
            XCTAssertTrue(isStorage(error as? OSINTFailure), "\(error)")
        }
        let keys = try await h.api.keys()
        XCTAssertTrue(keys.isEmpty, "no key without its journal row")
    }
}

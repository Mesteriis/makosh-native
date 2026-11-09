import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

final class OSINTServiceKeysTests: XCTestCase {
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

    func testSetKeyStoresValueInVaultAndNameOnServer() async throws {
        let h = try await harness()
        try await h.service.setKey(name: "HIBP_API_KEY", value: "hibp-secret-value")
        let stored = try await h.vault.key(name: "HIBP_API_KEY")
        XCTAssertEqual(stored, "hibp-secret-value")
        let keys = try await h.api.keys()
        XCTAssertEqual(keys.map(\.name), ["HIBP_API_KEY"])
        let snapshot = try await h.service.snapshot()
        XCTAssertEqual(snapshot.serverKeyNames, ["HIBP_API_KEY"])
        let rows = try h.db.execute("SELECT data::text FROM persons_osint_attempts")
        XCTAssertFalse(rows.joined().joined().contains("hibp-secret-value"))
        let attempts = try await h.store.attempts(open: false).filter { $0.kind == .createKey }
        XCTAssertEqual(attempts.map(\.state), [.confirmed])
        XCTAssertEqual(attempts.first?.payload.keyName, "HIBP_API_KEY")
    }

    func testSetKeyReplacesExisting() async throws {
        let h = try await harness()
        try await h.service.setKey(name: "WHOXY_API_KEY", value: "first")
        try await h.service.setKey(name: "WHOXY_API_KEY", value: "second")
        let keys = try await h.api.keys()
        XCTAssertEqual(keys.map(\.name), ["WHOXY_API_KEY"], "one key per name")
        let attempts = try await h.store.attempts(open: false)
        XCTAssertEqual(attempts.filter { $0.kind == .deleteKey }.count, 1)
        XCTAssertEqual(attempts.filter { $0.kind == .createKey }.count, 2)
        let stored = try await h.vault.key(name: "WHOXY_API_KEY")
        XCTAssertEqual(stored, "second")
    }

    func testUnknownKeyNameIsInvalidInput() async throws {
        let h = try await harness()
        do {
            try await h.service.setKey(name: "SOMETHING_ELSE", value: "x")
            XCTFail("unknown key")
        } catch { XCTAssertEqual(error as? OSINTFailure, .invalidInput("key name"), "\(error)") }
    }

    func testRemoveKeyDeletesBoth() async throws {
        let h = try await harness()
        try await h.service.setKey(name: "VERIPHONE_API_KEY", value: "v")
        try await h.service.removeKey(name: "VERIPHONE_API_KEY")
        let keys = try await h.api.keys()
        XCTAssertTrue(keys.isEmpty)
        let stored = try await h.vault.key(name: "VERIPHONE_API_KEY")
        XCTAssertNil(stored)
        let snapshot = try await h.service.snapshot()
        XCTAssertTrue(snapshot.serverKeyNames.isEmpty)
    }

    func testAcceptAndRejectPassThrough() async throws {
        let h = try await harness()
        let id = try anna(h)
        let inputs = try await h.service.inputs(personID: id)
        _ = try await h.service.enrich(personID: id, enrichers: [.emailToGravatar, .usernameToMaigret], inputs: inputs)
        await h.service.settled()
        let person = try XCTUnwrap(try h.persons.person(id: id))
        let avatar = try XCTUnwrap(person.observations.first { $0.field == "avatar" })
        let github = try XCTUnwrap(person.observations.first { $0.field == "social.github" })
        let accepted = try await h.service.acceptObservation(personID: id, observationID: avatar.id)
        XCTAssertEqual(accepted, .applied)
        try await h.service.rejectObservation(personID: id, observationID: github.id)
        let after = try XCTUnwrap(try h.persons.person(id: id))
        XCTAssertEqual(after.observations.first { $0.id == avatar.id }?.status, .confirmed)
        XCTAssertEqual(after.observations.first { $0.id == github.id }?.status, .rejected)
    }

    func testSnapshotCarriesOpenAttemptsAndLastRuns() async throws {
        let h = try await harness()
        let id = try anna(h)
        await h.api.failNext(.unknownOutcome(stage: "launch"), stage: "launch")
        let runID = try await h.service.enrich(
            personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let snapshot = try await h.service.snapshot()
        XCTAssertTrue(snapshot.connected)
        XCTAssertEqual(snapshot.settings.installedTag, "v1.2.13")
        XCTAssertEqual(snapshot.openAttempts.map(\.kind), [.launch])
        XCTAssertEqual(snapshot.lastRuns[id]?.id, runID)
        XCTAssertEqual(snapshot.lastRuns[id]?.state, .unknown)
        XCTAssertNotNil(snapshot.sketches[id])
        XCTAssertEqual(snapshot.lastInstall?.state, .completed)
        XCTAssertFalse(snapshot.installing)
    }

    func testGraphURLNilWithoutSketch() async throws {
        let h = try await harness()
        let id = try anna(h)
        let none = try await h.service.graphURL(personID: id)
        XCTAssertNil(none)
        _ = try await h.service.enrich(personID: id, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: Self.anna)])
        await h.service.settled()
        let urlValue = try await h.service.graphURL(personID: id)
        let url = try XCTUnwrap(urlValue)
        XCTAssertEqual(url.host, "127.0.0.1")
        let link = try await h.store.sketch(personID: id)
        XCTAssertTrue(url.path.contains(link!.sketchID), url.absoluteString)
        let root = try await h.service.webRootURL()
        XCTAssertEqual(root?.host, "127.0.0.1")
    }

    func testSetKeyStopsWhenDeleteIsUnknown() async throws {
        let h = try await harness()
        try await h.service.setKey(name: "WHOXY_API_KEY", value: "first")
        await h.api.failNext(.unknownOutcome(stage: "deleteKey"), stage: "deleteKey")
        do {
            try await h.service.setKey(name: "WHOXY_API_KEY", value: "second")
            XCTFail("an unknown delete must stop the replacement")
        } catch { XCTAssertEqual(error as? OSINTFailure, .unknownOutcome(stage: "deleteKey"), "\(error)") }
        let attempts = try await h.store.attempts(open: false)
        XCTAssertEqual(attempts.filter { $0.kind == .createKey }.count, 1, "no second key while the delete is unsettled")
        let open = try await h.store.attempts(open: true)
        XCTAssertEqual(open.map(\.kind), [.deleteKey])
        XCTAssertEqual(open.first?.state, .unknown)
    }

    func testRefreshKeysAlsoReadsServerEnrichers() async throws {
        let h = try await harness()
        await h.api.setOfferedEnrichers(["email_to_gravatar"])
        try await h.service.refreshKeys()
        let snapshot = try await h.service.snapshot()
        XCTAssertEqual(snapshot.serverEnricherNames, ["email_to_gravatar"])
    }
}

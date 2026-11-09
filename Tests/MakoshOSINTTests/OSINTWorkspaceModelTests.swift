import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

@MainActor
final class OSINTWorkspaceModelTests: XCTestCase {
    private var harnesses: [OSINTServiceHarness] = []

    override func tearDown() async throws {
        for harness in harnesses { await harness.stop() }
        harnesses = []
    }

    private func harness() async throws -> OSINTServiceHarness {
        let harness = try await OSINTServiceHarness(database: try osintDatabase(), findings: OSINTServiceRunTests.findings())
        harnesses.append(harness)
        return harness
    }

    func testLoadFillsSnapshot() async throws {
        let h = try await harness()
        try await h.installed()
        let model = OSINTWorkspaceModel(service: h.service)
        XCTAssertNil(model.snapshot)
        await model.load()
        let snapshot = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(snapshot.settings.installedTag, "v1.2.13")
        XCTAssertTrue(snapshot.connected)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
    }

    func testTestConnectionWaitsForTrustDecision() async throws {
        let h = try await harness()
        try await h.configure()
        let model = OSINTWorkspaceModel(service: h.service)
        let checking = Task { await model.testConnection() }
        for _ in 0..<300 where model.pendingFingerprint == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.pendingFingerprint, h.endpoint.fingerprint)
        model.trustPendingKey()
        let reportValue = await checking.value
        let report = try XCTUnwrap(reportValue)
        XCTAssertTrue(report.trusted)
        XCTAssertNil(model.pendingFingerprint)
        let settings = try await h.service.settings()
        XCTAssertEqual(settings.hostKeyFingerprint, h.endpoint.fingerprint)
        // A declined key leaves an error and nothing trusted.
        try await h.service.saveConnection(host: "127.0.0.2", port: h.endpoint.port, login: "makosh", password: nil)
        try await h.service.saveConnection(host: h.endpoint.host, port: h.endpoint.port, login: "makosh", password: nil)
        let declining = Task { await model.testConnection() }
        for _ in 0..<300 where model.pendingFingerprint == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.declinePendingKey()
        let declined = await declining.value
        XCTAssertNil(declined)
        XCTAssertNotNil(model.error)
    }

    func testInstallAppendsLogLines() async throws {
        let h = try await harness()
        try await h.configure()
        try await h.trust()
        let model = OSINTWorkspaceModel(service: h.service)
        await model.install()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.installLog.isEmpty)
        XCTAssertTrue(model.installLog.contains { $0.hasPrefix("Проверка Docker") }, model.installLog.joined(separator: "\n"))
        XCTAssertTrue(model.installLog.contains { $0.contains("готово") || $0.contains("пропущено") })
        XCTAssertEqual(model.snapshot?.lastInstall?.state, .completed)
    }

    func testErrorsAreHumanReadable() {
        XCTAssertTrue(OSINTWorkspaceModel.describe(.notInstalled).contains("не установлен"))
        XCTAssertTrue(OSINTWorkspaceModel.describe(.hostKeyMismatch).contains("ключ"))
        XCTAssertTrue(OSINTWorkspaceModel.describe(.serviceAuthFailed).contains("пароль"))
        XCTAssertTrue(OSINTWorkspaceModel.describe(.apiRejected(code: 422, stage: "launch")).contains("422"))
        XCTAssertFalse(OSINTWorkspaceModel.describe(.disabled).isEmpty)
    }

    func testEnrichReloadsSnapshotWhenRunSettles() async throws {
        let h = try await harness()
        try await h.installed()
        let person = try h.persons.createPerson(
            draft: .init(displayName: "Анна Каренина", emails: [OSINTServiceRunTests.anna], usernames: ["anna_k"]))
        let model = OSINTWorkspaceModel(service: h.service)
        await model.load()
        let settledBefore = model.runsSettled
        let queued = await model.enrich(
            personID: person, enrichers: [.emailToGravatar], inputs: [OSINTInput(type: .email, value: OSINTServiceRunTests.anna)])
        XCTAssertTrue(queued)
        // The card must not stay on «Идёт запуск…»: the model reloads itself once the runner is done.
        for _ in 0..<500 where model.runsSettled == settledBefore { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.runsSettled, settledBefore + 1)
        XCTAssertEqual(model.snapshot?.lastRuns[person]?.state, .completed)
        XCTAssertEqual(model.snapshot?.lastRuns[person]?.found, 1)
    }
}

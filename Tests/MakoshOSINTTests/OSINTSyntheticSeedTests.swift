import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshOSINT

final class OSINTSyntheticSeedTests: XCTestCase {
    private struct Fixture {
        let db: OSINTTestDatabase
        let persons: PersonStore
        let store: OSINTStore
        let synthetic: FlowsintSynthetic
        let server: OSINTSyntheticSSHServer
        let service: OSINTService
        let endpoint: (host: String, port: Int, fingerprint: String)
        let anna: UUID
        let boris: UUID
    }

    private func fixture() async throws -> Fixture {
        let db = try osintDatabase()
        let persons = try db.persons()
        let anna = try persons.createPerson(
            draft: PersonDraft(displayName: "Анна Сидорова", phones: ["+7 916 100-00-01"], emails: ["anna@sidorov.ru"], usernames: ["anna"])
        )
        let boris = try persons.createPerson(
            draft: PersonDraft(displayName: "Борис Сидоров", phones: ["+7 916 100-00-02"], emails: ["boris@sidorov.ru"]))
        let synthetic = FlowsintSynthetic(findings: OSINTSyntheticSeed.findings(), installed: false)
        let (server, _) = OSINTSyntheticSeed.scriptedServer(synthetic: synthetic)
        let endpoint = try await server.start()
        let store = OSINTStore(connectionString: db.connectionString, schema: db.schema)
        let (session, _) = OSINTService.liveFactories()
        let service = OSINTService(
            persons: persons, store: store, vault: OSINTCredentialVault(access: .memory()), sessionFactory: session,
            apiFactory: { _, _, _ in synthetic }, pollInterval: .milliseconds(20), healthPoll: .milliseconds(20))
        try await service.open()
        return Fixture(
            db: db, persons: persons, store: store, synthetic: synthetic, server: server, service: service, endpoint: endpoint, anna: anna,
            boris: boris)
    }

    private func seed(_ f: Fixture) async throws {
        try await OSINTSyntheticSeed.seed(
            service: f.service, synthetic: f.synthetic, persons: f.persons, annaID: f.anna, borisID: f.boris,
            host: f.endpoint.host, port: f.endpoint.port)
    }

    func testSeedInstallsAndEnrichesAnna() async throws {
        let f = try await fixture()
        defer {
            _Concurrency.Task {
                await f.service.close()
                await f.server.stop()
            }
        }
        try await seed(f)
        let installs = try await f.store.installs()
        XCTAssertEqual(installs.count, 1)
        XCTAssertEqual(installs.first?.state, .completed, "\(installs.first?.steps ?? [])")
        let anna = try XCTUnwrap(f.persons.person(id: f.anna))
        let proposed = anna.observations.filter { $0.status == .proposed && $0.source.identity.service == OSINTGraphMapping.service }
        XCTAssertEqual(proposed.count, 5, "\(proposed.map { "\($0.field)=\($0.value)" })")
        XCTAssertEqual(Set(proposed.map(\.field)), ["avatar", "breach", "social.github", "social.twitter", "phone.info"])
        let open = try await f.store.attempts(open: true)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.state, .unknown)
        XCTAssertEqual(open.first?.personID, f.boris)
        let settings = try await f.service.settings()
        XCTAssertEqual(settings.host, "127.0.0.1")
        XCTAssertTrue(settings.enabled)
        XCTAssertNotNil(settings.hostKeyFingerprint)
    }

    func testSeedIsIdempotent() async throws {
        let f = try await fixture()
        defer {
            _Concurrency.Task {
                await f.service.close()
                await f.server.stop()
            }
        }
        try await seed(f)
        let sketches = try await f.store.sketches().count
        let runs = try await f.store.runs(open: false).count
        let installs = try await f.store.installs().count
        XCTAssertEqual(sketches, 2)
        XCTAssertEqual(runs, 2)
        try await seed(f)
        let sketchesAfter = try await f.store.sketches().count
        let runsAfter = try await f.store.runs(open: false).count
        let installsAfter = try await f.store.installs().count
        XCTAssertEqual(sketchesAfter, sketches)
        XCTAssertEqual(runsAfter, runs)
        XCTAssertEqual(installsAfter, installs)
    }

    func testQAIsolationRefusesRemoteHost() throws {
        var settings = OSINTSettings(serverID: UUID())
        settings.host = "10.34.10.64"
        XCTAssertThrowsError(try OSINTQAIsolation.validate(settings: settings, synthetic: true)) {
            XCTAssertEqual($0 as? OSINTQAIsolation.Failure, .invalidConfiguration)
        }
        XCTAssertNoThrow(try OSINTQAIsolation.validate(settings: settings, synthetic: false))
        settings.host = "127.0.0.1"
        XCTAssertNoThrow(try OSINTQAIsolation.validate(settings: settings, synthetic: true))
    }
}

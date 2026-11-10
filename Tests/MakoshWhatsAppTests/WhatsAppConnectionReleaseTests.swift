import Foundation
import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppConnectionReleaseTests: XCTestCase {
    /// Destruction retires libpq off the releasing executor. The server (or
    /// PgBouncer) must also process disconnect/reset before another session owns the lease.
    func testReleasedDatabaseFreesSessionLocksAfterAsyncTeardown() async throws {
        let connection = try connectionString()
        let schema = "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let config = PersonWorkspaceConfiguration(connectionString: connection, schema: schema)
        let keys: (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x7a, count: 32) }
        let id = UUID().uuidString
        var first: WhatsAppPostgres? = try WhatsAppPostgres(configuration: config, keyProvider: keys)
        weak var released = first
        let second = try WhatsAppPostgres(configuration: config, keyProvider: keys)
        defer {
            _ = try? second.query("SELECT pg_advisory_unlock_all()")
            _ = try? second.query("DROP SCHEMA IF EXISTS \"\(schema)\" CASCADE")
        }
        XCTAssertEqual(try first?.query(Self.lock, [id]).first?.first, "t")
        // A commit must not release a live session's lock (transaction pooling would).
        _ = try first?.query("BEGIN")
        _ = try first?.query("SELECT 1")
        _ = try first?.query("COMMIT")
        XCTAssertEqual(try second.query(Self.lock, [id]).first?.first, "f")
        first = nil
        XCTAssertNil(released, "The store itself must not be retained by teardown")
        try await waitForLease { try second.query(Self.lock, [id]).first?.first == "t" }
    }

    func testExplicitCloseReleasesLeaseAndNextSessionHasNoLeakedState() async throws {
        let connection = try connectionString()
        let first = try PostgresConnection(connectionString: connection)
        let second = try PostgresConnection(connectionString: connection)
        defer { try? second.execute("SELECT pg_advisory_unlock_all()") }
        let id = UUID().uuidString
        let marker = "qa_" + UUID().uuidString
        try first.execute("SELECT set_config('application_name',$1,false)", [marker])
        XCTAssertEqual(try first.query(Self.lock, [id]).first?.first, "t")
        XCTAssertEqual(try second.query(Self.lock, [id]).first?.first, "f")
        first.close()
        first.close()  // Explicit retirement is idempotent.
        XCTAssertFalse(first.isOpen)
        XCTAssertThrowsError(try first.query("SELECT 1"))
        try await waitForLease { try second.query(Self.lock, [id]).first?.first == "t" }
        let replacement = try PostgresConnection(connectionString: connection)
        defer { replacement.close() }
        XCTAssertNotEqual(try replacement.query("SHOW application_name").first?.first, marker)
    }

    private static let lock = "SELECT pg_try_advisory_lock(hashtextextended($1,17402))"

    private func connectionString() throws -> String {
        guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !connection.isEmpty else {
            throw XCTSkip("PostgreSQL required")
        }
        return connection
    }

    private func waitForLease(_ acquired: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if try acquired() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Retired session did not release its advisory lease within five seconds")
    }
}

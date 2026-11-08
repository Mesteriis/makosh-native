import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppConnectionReleaseTests: XCTestCase {
    /// Outbox and batch leases are session advisory locks: a replacement
    /// repository must be able to claim them as soon as the old one is gone.
    func testReleasedDatabaseFreesSessionLocksImmediately() throws {
        guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
            throw XCTSkip("PostgreSQL required")
        }
        let schema = "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let config = PersonWorkspaceConfiguration(connectionString: connection, schema: schema)
        let keys: (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x7a, count: 32) }
        let lock = "SELECT pg_try_advisory_lock(hashtextextended($1,17402))"
        let id = UUID().uuidString
        var first: WhatsAppPostgres? = try WhatsAppPostgres(configuration: config, keyProvider: keys)
        let second = try WhatsAppPostgres(configuration: config, keyProvider: keys)
        defer { _ = try? second.query("DROP SCHEMA IF EXISTS \"\(schema)\" CASCADE") }
        XCTAssertEqual(try first?.query(lock, [id]).first?.first, "t")
        XCTAssertEqual(try second.query(lock, [id]).first?.first, "f")
        first = nil
        XCTAssertEqual(try second.query(lock, [id]).first?.first, "t")
    }
}

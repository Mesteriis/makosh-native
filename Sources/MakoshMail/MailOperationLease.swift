import Foundation
import CryptoKit
import MakoshCore

/// A separate PostgreSQL session owns a live write attempt across windows/processes.
/// Crashes close the session and release the lock; wall-clock expiry never permits replay.
final class MailOperationLease: @unchecked Sendable {
    private let connection: PostgresConnection
    init(configuration: ContactWorkspaceConfiguration, kind: String, id: UUID) throws {
        do { connection = try PostgresConnection(connectionString: configuration.connectionString) } catch { throw MailFailure.storage }
        let digest = SHA256.hash(data: Data(("makosh-mail|" + configuration.schema + "|" + kind + "|" + id.uuidString).utf8))
        let raw = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let acquired: Bool
        do { acquired = try connection.query("SELECT pg_try_advisory_lock($1::bigint)", [String(Int64(bitPattern: raw))]) == [["t"]] } catch
        {
            connection.close()
            throw MailFailure.storage
        }
        guard acquired else {
            connection.close()
            throw MailFailure.busy
        }
    }
    // Close synchronously: the session advisory lock must be free when the lease is gone.
    deinit { connection.close() }
}

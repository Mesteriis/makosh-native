import Foundation
import CryptoKit
import CPostgres
import MakoshCore

/// A separate PostgreSQL session owns a live write attempt across windows/processes.
/// Crashes close the session and release the lock; wall-clock expiry never permits replay.
final class MailOperationLease: @unchecked Sendable {
    private var connection: OpaquePointer?
    init(configuration: ContactWorkspaceConfiguration, kind: String, id: UUID) throws {
        connection = configuration.connectionString.withCString { dsn in
            "dbname".withCString { key in "connect_timeout".withCString { timeout in "5".withCString { seconds in
                let keys: [UnsafePointer<CChar>?] = [key, timeout, nil], values: [UnsafePointer<CChar>?] = [dsn, seconds, nil]
                return keys.withUnsafeBufferPointer { ks in values.withUnsafeBufferPointer { vs in PQconnectdbParams(ks.baseAddress, vs.baseAddress, 1) } }
            } } }
        }
        guard let connection, PQstatus(connection) == CONNECTION_OK else { if let connection { PQfinish(connection) }; self.connection = nil; throw MailFailure.storage }
        PQsetNoticeProcessor(connection, { _,_ in }, nil)
        let digest = SHA256.hash(data: Data(("makosh-mail|" + configuration.schema + "|" + kind + "|" + id.uuidString).utf8))
        let raw = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let number = String(Int64(bitPattern: raw))
        let result = number.withCString { value in
            let values: [UnsafePointer<CChar>?] = [value]
            return values.withUnsafeBufferPointer { PQexecParams(connection, "SELECT pg_try_advisory_lock($1::bigint)", 1, nil, $0.baseAddress, nil, nil, 0) }
        }
        guard let result else { PQfinish(connection); self.connection = nil; throw MailFailure.storage }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_TUPLES_OK, PQntuples(result) == 1 else { PQfinish(connection); self.connection = nil; throw MailFailure.storage }
        guard String(cString: PQgetvalue(result, 0, 0)) == "t" else { PQfinish(connection); self.connection = nil; throw MailFailure.busy }
    }
    deinit { if let connection { PQfinish(connection) } }
}

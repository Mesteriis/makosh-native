import Foundation
import CryptoKit
import CPostgres
import MakoshCore

private struct TeamsPGHandle: @unchecked Sendable { let value: OpaquePointer }

/// Pure construction; the repository/lease actor explicitly opens and closes the connection.
final class TeamsPGConnection {
    private var handle: OpaquePointer?
    private let dsn: String
    init(dsn: String) { self.dsn = dsn }
    func open() throws {
        guard handle == nil, !dsn.utf8.contains(0) else { throw TeamsFailure.storage }
        handle = dsn.withCString { value in
            "dbname".withCString { name in "connect_timeout".withCString { timeout in "5".withCString { seconds in
                let keys: [UnsafePointer<CChar>?] = [name, timeout, nil]
                let values: [UnsafePointer<CChar>?] = [value, seconds, nil]
                return keys.withUnsafeBufferPointer { k in values.withUnsafeBufferPointer { v in PQconnectdbParams(k.baseAddress, v.baseAddress, 1) } }
            } } }
        }
        guard let handle, PQstatus(handle) == CONNECTION_OK else { close(); throw TeamsFailure.storage }
        PQsetNoticeProcessor(handle, { _, _ in }, nil)
        _ = try query("SET client_encoding TO 'UTF8'")
        _ = try query("SET statement_timeout TO '15s'")
        _ = try query("SET lock_timeout TO '5s'")
    }
    func close() { if let handle { PQfinish(handle) }; handle = nil }
    deinit {
        if let handle {
            let owned = TeamsPGHandle(value: handle)
            DispatchQueue.global(qos: .utility).async { PQfinish(owned.value) }
        }
    }
    func query(_ sql: String, _ parameters: [String] = []) throws -> [[String]] {
        guard let handle, parameters.count <= Int(Int32.max), !parameters.contains(where: { $0.utf8.contains(0) }) else { throw TeamsFailure.storage }
        let pointers = parameters.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        let values = pointers.map { UnsafePointer<CChar>($0) }
        let result = values.withUnsafeBufferPointer { PQexecParams(handle, sql, Int32(parameters.count), nil, $0.baseAddress, nil, nil, 0) }
        guard let result else { throw TeamsFailure.storage }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_TUPLES_OK || PQresultStatus(result) == PGRES_COMMAND_OK else { throw TeamsFailure.storage }
        return (0..<PQntuples(result)).map { row in (0..<PQnfields(result)).map { String(cString: PQgetvalue(result, row, $0)) } }
    }
}

/// Confined to TeamsRepository. Separate domain keys and authenticated row identities protect ciphertext/indexes.
final class TeamsPostgres {
    let configuration: ContactWorkspaceConfiguration
    let connection: TeamsPGConnection
    let prefix: String
    private var encryptionKey: SymmetricKey?
    private var lookupKey: SymmetricKey?
    private var vault: UUID?
    private(set) var blocked = false
    init(configuration: ContactWorkspaceConfiguration) throws {
        guard ArchiveBackup.isValidSchemaName(configuration.schema), !configuration.connectionString.utf8.contains(0) else { throw TeamsFailure.invalidConfiguration }
        self.configuration = configuration
        prefix = "\"\(configuration.schema)\"."
        connection = TeamsPGConnection(dsn: configuration.connectionString)
    }
    func open(keyProvider: (UUID, Bool) throws -> Data) throws {
        try connection.open()
        do {
            try transaction {
                _ = try query("SELECT pg_advisory_xact_lock(hashtext('makosh-teams-schema'),hashtext($1))", [configuration.schema])
                _ = try query("CREATE SCHEMA IF NOT EXISTS \"\(configuration.schema)\"")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_metadata(id SMALLINT PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,vault UUID NOT NULL,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_accounts(token TEXT PRIMARY KEY,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_current(token TEXT PRIMARY KEY,scope TEXT NOT NULL,sequence BIGINT NOT NULL,conflict BOOLEAN NOT NULL,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_versions(sequence BIGSERIAL PRIMARY KEY,observation UUID NOT NULL UNIQUE,scope TEXT NOT NULL,message TEXT NOT NULL,digest TEXT NOT NULL,visible BOOLEAN NOT NULL,ciphertext TEXT NOT NULL,UNIQUE(message,digest))")
                _ = try query("CREATE INDEX IF NOT EXISTS teams_version_page ON \(prefix)teams_versions(scope,sequence DESC)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_checkpoints(token TEXT PRIMARY KEY,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_archive_jobs(id UUID PRIMARY KEY,sequence BIGINT NOT NULL,acked BOOLEAN NOT NULL DEFAULT false,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE INDEX IF NOT EXISTS teams_archive_pending ON \(prefix)teams_archive_jobs(acked,sequence)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_directory(token TEXT PRIMARY KEY,account TEXT NOT NULL,category TEXT NOT NULL,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_outbox(sequence BIGSERIAL UNIQUE,token TEXT PRIMARY KEY,account TEXT NOT NULL,state TEXT NOT NULL,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE INDEX IF NOT EXISTS teams_outbox_page ON \(prefix)teams_outbox(account,sequence DESC)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_prepared_files(token TEXT PRIMARY KEY,scope TEXT NOT NULL,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_file_plans(token TEXT PRIMARY KEY,scope TEXT NOT NULL,outgoing UUID,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_incoming_files(token TEXT PRIMARY KEY,scope TEXT NOT NULL,account TEXT NOT NULL,message TEXT NOT NULL,attachment TEXT NOT NULL,sequence BIGINT NOT NULL,pending BOOLEAN NOT NULL,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_preferences(token TEXT PRIMARY KEY,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_notifications(token TEXT PRIMARY KEY,account TEXT NOT NULL,sequence BIGINT NOT NULL,state TEXT NOT NULL,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_local_unread(token TEXT PRIMARY KEY,scope TEXT NOT NULL,exactscope TEXT NOT NULL,sequence BIGINT NOT NULL,read BOOLEAN NOT NULL,ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)teams_message_order(message TEXT PRIMARY KEY,scope TEXT NOT NULL,epoch BIGINT NOT NULL,position BIGINT NOT NULL,first_sequence BIGINT NOT NULL)")
                let rows = try query("SELECT version,vault,ciphertext FROM \(prefix)teams_metadata WHERE id=1 FOR UPDATE")
                let id: UUID
                if let row = rows.first {
                    guard row[0] == "1", let existing = UUID(uuidString: row[1]) else { throw TeamsFailure.storage }
                    id = existing
                } else {
                    for table in ["teams_accounts", "teams_current", "teams_versions", "teams_checkpoints", "teams_archive_jobs", "teams_directory", "teams_outbox", "teams_prepared_files", "teams_file_plans", "teams_incoming_files", "teams_preferences", "teams_notifications", "teams_local_unread", "teams_message_order"] {
                        guard try query("SELECT 1 FROM \(prefix)\(table) LIMIT 1").isEmpty else { throw TeamsFailure.keyUnavailable }
                    }
                    id = UUID()
                }
                vault = id
                let raw: Data
                do { raw = try keyProvider(id, rows.isEmpty) } catch { throw TeamsFailure.keyUnavailable }
                guard raw.count == 32 else { throw TeamsFailure.keyUnavailable }
                encryptionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(id.uuidString.utf8), info: Data("makosh-teams-encryption-v1".utf8), outputByteCount: 32)
                lookupKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(id.uuidString.utf8), info: Data("makosh-teams-lookup-v1".utf8), outputByteCount: 32)
                if let row = rows.first {
                    guard (try? decode(row[2], token: "key-check") as String) == "makosh-teams-key-check-v1" else { throw TeamsFailure.keyUnavailable }
                } else {
                    _ = try query("INSERT INTO \(prefix)teams_metadata VALUES(1,1,$1::uuid,$2)", [id.uuidString, try seal("makosh-teams-key-check-v1", token: "key-check")])
                }
                _ = try query("CREATE OR REPLACE FUNCTION \(prefix)teams_no_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'append only'; END $$")
                _ = try query("DROP TRIGGER IF EXISTS teams_no_rewrite ON \(prefix)teams_versions")
                _ = try query("CREATE TRIGGER teams_no_rewrite BEFORE UPDATE OR DELETE OR TRUNCATE ON \(prefix)teams_versions FOR EACH STATEMENT EXECUTE FUNCTION \(prefix)teams_no_rewrite()")
            }
        } catch { connection.close(); throw error }
    }
    func close() { connection.close() }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard !blocked else { throw TeamsFailure.storage }
        _ = try query("BEGIN")
        do {
            let value = try body()
            do { _ = try query("COMMIT") } catch { blocked = true; throw error }
            return value
        } catch { _ = try? connection.query("ROLLBACK"); throw error }
    }
    @discardableResult
    func query(_ sql: String, _ parameters: [String] = []) throws -> [[String]] {
        guard !blocked else { throw TeamsFailure.storage }
        return try connection.query(sql, parameters)
    }
    func token(_ data: Data) throws -> String {
        guard let lookupKey else { throw TeamsFailure.storage }
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: lookupKey)).teamsBase64URL
    }
    func token(_ fields: [String]) throws -> String { try token(teamsIdentityKey(fields)) }
    func seal<T: Encodable>(_ value: T, token: String) throws -> String {
        guard let encryptionKey, let vault else { throw TeamsFailure.storage }
        let data = try encoded(value)
        guard let sealed = try AES.GCM.seal(data, using: encryptionKey, authenticating: teamsIdentityKey([vault.uuidString, token])).combined else { throw TeamsFailure.storage }
        return sealed.base64EncodedString()
    }
    func decode<T: Decodable>(_ value: String, token: String) throws -> T {
        guard let encryptionKey, let vault, let data = Data(base64Encoded: value), data.count <= 6 * 1024 * 1024 else { throw TeamsFailure.storage }
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encryptionKey, authenticating: teamsIdentityKey([vault.uuidString, token]))
            return try JSONDecoder().decode(T.self, from: plain)
        } catch { throw TeamsFailure.storage }
    }
    func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 4 * 1024 * 1024 else { throw TeamsFailure.invalidResource }
        return data
    }
}

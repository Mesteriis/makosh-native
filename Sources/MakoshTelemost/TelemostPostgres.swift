import Foundation
import CryptoKit
import CPostgres
import MakoshCore

private struct TelemostPGHandle: @unchecked Sendable { let value: OpaquePointer }

/// Only accessed by its owning repository executor, including lease connections.
final class TelemostPGConnection {
    private var handle: OpaquePointer?
    let dsn: String
    init(dsn: String) { self.dsn = dsn }
    func open() throws {
        guard handle == nil, !dsn.utf8.contains(0) else { throw TelemostFailure.storage }
        handle = dsn.withCString { value in
            "dbname".withCString { name in "connect_timeout".withCString { timeout in "5".withCString { seconds in
                let keys: [UnsafePointer<CChar>?] = [name, timeout, nil], values: [UnsafePointer<CChar>?] = [value, seconds, nil]
                return keys.withUnsafeBufferPointer { k in values.withUnsafeBufferPointer { v in PQconnectdbParams(k.baseAddress, v.baseAddress, 1) } }
            } } }
        }
        guard let handle, PQstatus(handle) == CONNECTION_OK else { close(); throw TelemostFailure.storage }
        PQsetNoticeProcessor(handle, { _, _ in }, nil)
        _ = try query("SET client_encoding TO 'UTF8'")
        _ = try query("SET statement_timeout TO '15s'")
        _ = try query("SET lock_timeout TO '5s'")
    }
    func close() { if let handle { PQfinish(handle) }; handle = nil }
    deinit {
        if let handle {
            let owned = TelemostPGHandle(value: handle)
            DispatchQueue.global(qos: .utility).async { PQfinish(owned.value) }
        }
    }
    @discardableResult
    func query(_ sql: String, _ parameters: [String] = []) throws -> [[String]] {
        guard let handle, parameters.count <= Int(Int32.max), !parameters.contains(where: { $0.utf8.contains(0) }) else { throw TelemostFailure.storage }
        let pointers = parameters.map { strdup($0) }; defer { pointers.forEach { free($0) } }
        let values = pointers.map { UnsafePointer<CChar>($0) }
        let result = values.withUnsafeBufferPointer { PQexecParams(handle, sql, Int32(parameters.count), nil, $0.baseAddress, nil, nil, 0) }
        guard let result else { throw TelemostFailure.storage }; defer { PQclear(result) }
        guard [PGRES_TUPLES_OK, PGRES_COMMAND_OK].contains(PQresultStatus(result)) else { throw TelemostFailure.storage }
        return (0..<PQntuples(result)).map { row in (0..<PQnfields(result)).map { String(cString: PQgetvalue(result, row, $0)) } }
    }
}

final class TelemostPostgres {
    let configuration: ContactWorkspaceConfiguration
    let connection: TelemostPGConnection
    let prefix: String
    private(set) var blocked = false
    private(set) var localArea: UUID?
    private var vault: UUID?
    private var encryptionKey: SymmetricKey?
    private var lookupKey: SymmetricKey?
    init(configuration: ContactWorkspaceConfiguration) throws {
        guard ArchiveBackup.isValidSchemaName(configuration.schema), !configuration.connectionString.utf8.contains(0) else { throw TelemostFailure.invalidConfiguration }
        self.configuration = configuration; prefix = "\"\(configuration.schema)\"."
        connection = TelemostPGConnection(dsn: configuration.connectionString)
    }
    func open(keyProvider: (UUID, Bool) throws -> Data) throws {
        try connection.open()
        do {
            try transaction {
                try query("SELECT pg_advisory_xact_lock(hashtext('makosh-telemost-schema'),hashtext($1))", [configuration.schema])
                try query("CREATE SCHEMA IF NOT EXISTS \"\(configuration.schema)\"")
                try query("CREATE TABLE IF NOT EXISTS \(prefix)telemost_metadata(id SMALLINT PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,vault UUID NOT NULL,ciphertext TEXT NOT NULL)")
                try query("CREATE TABLE IF NOT EXISTS \(prefix)telemost_records(token TEXT PRIMARY KEY,kind TEXT NOT NULL,owner TEXT NOT NULL,status TEXT NOT NULL,sequence BIGSERIAL UNIQUE,ciphertext TEXT NOT NULL)")
                try query("CREATE INDEX IF NOT EXISTS telemost_record_owner ON \(prefix)telemost_records(kind,owner,sequence DESC)")
                try query("CREATE TABLE IF NOT EXISTS \(prefix)telemost_versions(sequence BIGSERIAL PRIMARY KEY,token TEXT NOT NULL,kind TEXT NOT NULL,owner TEXT NOT NULL,ciphertext TEXT NOT NULL)")
                try query("CREATE INDEX IF NOT EXISTS telemost_version_owner ON \(prefix)telemost_versions(kind,owner,sequence DESC)")
                let rows = try query("SELECT version,vault,ciphertext FROM \(prefix)telemost_metadata WHERE id=1 FOR UPDATE")
                let id: UUID
                if let row = rows.first {
                    guard row[0] == "1", let value = UUID(uuidString: row[1]) else { throw TelemostFailure.storage }; id = value
                } else {
                    for table in ["telemost_records", "telemost_versions"] {
                        guard try query("SELECT 1 FROM \(prefix)\(table) LIMIT 1").isEmpty else { throw TelemostFailure.keyUnavailable }
                    }
                    id = UUID()
                }
                vault = id
                let raw: Data
                do { raw = try keyProvider(id, rows.isEmpty) } catch { throw TelemostFailure.keyUnavailable }
                guard raw.count == 32 else { throw TelemostFailure.keyUnavailable }
                encryptionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: .init(data: raw), salt: Data(id.uuidString.utf8), info: Data("makosh-telemost-encryption-v1".utf8), outputByteCount: 32)
                lookupKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: .init(data: raw), salt: Data(id.uuidString.utf8), info: Data("makosh-telemost-lookup-v1".utf8), outputByteCount: 32)
                if let row = rows.first {
                    guard let marker: [String] = try? decode(row[2], token: "key-check"),
                          marker.count == 2, marker[0] == "makosh-telemost-key-check-v1", let area = UUID(uuidString: marker[1]) else { throw TelemostFailure.keyUnavailable }
                    localArea = area
                } else {
                    let area = UUID(); localArea = area
                    try query("INSERT INTO \(prefix)telemost_metadata VALUES(1,1,$1::uuid,$2)", [id.uuidString, try seal(["makosh-telemost-key-check-v1", area.uuidString], token: "key-check")])
                }
                try query("CREATE OR REPLACE FUNCTION \(prefix)telemost_no_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'append only'; END $$")
                try query("DROP TRIGGER IF EXISTS telemost_no_rewrite ON \(prefix)telemost_versions")
                try query("CREATE TRIGGER telemost_no_rewrite BEFORE UPDATE OR DELETE OR TRUNCATE ON \(prefix)telemost_versions FOR EACH STATEMENT EXECUTE FUNCTION \(prefix)telemost_no_rewrite()")
            }
        } catch { connection.close(); throw error }
    }
    func close() { connection.close() }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard !blocked else { throw TelemostFailure.storage }
        try query("BEGIN")
        do {
            // Short storage transactions also serialize absent-row creation across windows.
            try query("SELECT pg_advisory_xact_lock(hashtext('makosh-telemost-write'),hashtext($1))", [configuration.schema])
            let result = try body()
            do { try query("COMMIT") } catch { blocked = true; throw error }
            return result
        } catch { _ = try? connection.query("ROLLBACK"); throw error }
    }
    @discardableResult
    func query(_ sql: String, _ parameters: [String] = []) throws -> [[String]] {
        guard !blocked else { throw TelemostFailure.storage }; return try connection.query(sql, parameters)
    }
    func token(_ fields: [String]) throws -> String {
        guard let lookupKey else { throw TelemostFailure.storage }
        return Data(HMAC<SHA256>.authenticationCode(for: Data(telemostIdentityKey(fields).utf8), using: lookupKey)).base64EncodedString()
    }
    func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = try encoder.encode(value)
        guard value.count <= 6 * 1024 * 1024 else { throw TelemostFailure.bodyTooLarge }; return value
    }
    func seal<T: Encodable>(_ value: T, token: String) throws -> String {
        guard let encryptionKey, let vault,
              let sealed = try AES.GCM.seal(encoded(value), using: encryptionKey,
                authenticating: Data(telemostIdentityKey([vault.uuidString, token]).utf8)).combined else { throw TelemostFailure.storage }
        return sealed.base64EncodedString()
    }
    func decode<T: Decodable>(_ value: String, token: String) throws -> T {
        guard let encryptionKey, let vault, let encrypted = Data(base64Encoded: value), encrypted.count <= 8 * 1024 * 1024 else { throw TelemostFailure.storage }
        do {
            let data = try AES.GCM.open(.init(combined: encrypted), using: encryptionKey, authenticating: Data(telemostIdentityKey([vault.uuidString, token]).utf8))
            guard data.count <= 6 * 1024 * 1024 else { throw TelemostFailure.storage }
            return try JSONDecoder().decode(T.self, from: data)
        } catch { throw TelemostFailure.storage }
    }
}

import CryptoKit
import Foundation
import MakoshCore

/// Length-prefixed so that field boundaries cannot be forged by content.
func aiIdentityKey(_ fields: [String]) -> String { fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|") }

/// Owned and closed by `AIRepository`; every value is AES-GCM sealed with a
/// key derived from the shared archive vault key.
final class AIPostgres {
    let configuration: ContactWorkspaceConfiguration
    let prefix: String
    private var connection: PostgresConnection?
    private var vault: UUID?
    private var encryptionKey: SymmetricKey?
    private var lookupKey: SymmetricKey?

    init(configuration: ContactWorkspaceConfiguration) throws {
        guard ArchiveBackup.isValidSchemaName(configuration.schema), !configuration.connectionString.utf8.contains(0) else {
            throw AIFailure.invalidConfiguration
        }
        self.configuration = configuration
        prefix = "\"\(configuration.schema)\"."
    }

    func open(keyProvider: (UUID, Bool) throws -> Data) throws {
        do { connection = try PostgresConnection(connectionString: configuration.connectionString) } catch { throw AIFailure.storage }
        do {
            try transaction {
                try query("SELECT pg_advisory_xact_lock(hashtext('makosh-ai-schema'),hashtext($1))", [configuration.schema])
                try query("CREATE SCHEMA IF NOT EXISTS \"\(configuration.schema)\"")
                try query(
                    "CREATE TABLE IF NOT EXISTS \(prefix)ai_metadata(id SMALLINT PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,vault UUID NOT NULL,ciphertext TEXT NOT NULL)"
                )
                try query(
                    "CREATE TABLE IF NOT EXISTS \(prefix)ai_records(token TEXT PRIMARY KEY,kind TEXT NOT NULL,owner TEXT NOT NULL,sequence BIGSERIAL UNIQUE,ciphertext TEXT NOT NULL)"
                )
                try query("CREATE INDEX IF NOT EXISTS ai_record_owner ON \(prefix)ai_records(kind,owner)")
                let rows = try query("SELECT version,vault,ciphertext FROM \(prefix)ai_metadata WHERE id=1 FOR UPDATE")
                let id: UUID
                if let row = rows.first {
                    guard row[0] == "1", let value = UUID(uuidString: row[1]) else { throw AIFailure.storage }
                    id = value
                } else {
                    guard try query("SELECT 1 FROM \(prefix)ai_records LIMIT 1").isEmpty else { throw AIFailure.keyUnavailable }
                    id = UUID()
                }
                vault = id
                let raw: Data
                do { raw = try keyProvider(id, rows.isEmpty) } catch { throw AIFailure.keyUnavailable }
                guard raw.count == 32 else { throw AIFailure.keyUnavailable }
                let salt = Data(id.uuidString.utf8)
                encryptionKey = HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: .init(data: raw), salt: salt, info: Data("makosh-ai-encryption-v1".utf8), outputByteCount: 32)
                lookupKey = HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: .init(data: raw), salt: salt, info: Data("makosh-ai-lookup-v1".utf8), outputByteCount: 32)
                if let row = rows.first {
                    guard let marker: String = try? decode(row[2], token: "key-check"), marker == "makosh-ai-key-check-v1" else {
                        throw AIFailure.keyUnavailable
                    }
                } else {
                    try query(
                        "INSERT INTO \(prefix)ai_metadata VALUES(1,1,$1::uuid,$2)",
                        [id.uuidString, try seal("makosh-ai-key-check-v1", token: "key-check")])
                }
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        connection?.close()
        connection = nil
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try query("BEGIN")
        do {
            let result = try body()
            try query("COMMIT")
            return result
        } catch {
            _ = try? connection?.query("ROLLBACK", [])
            throw error
        }
    }

    @discardableResult
    func query(_ sql: String, _ parameters: [String] = []) throws -> [[String]] {
        guard let connection else { throw AIFailure.storage }
        do { return try connection.query(sql, parameters) } catch { throw AIFailure.storage }
    }

    func token(_ fields: [String]) throws -> String {
        guard let lookupKey else { throw AIFailure.storage }
        return Data(HMAC<SHA256>.authenticationCode(for: Data(aiIdentityKey(fields).utf8), using: lookupKey)).base64EncodedString()
    }

    func seal<T: Encodable>(_ value: T, token: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 6 * 1024 * 1024, let encryptionKey, let vault,
            let sealed = try AES.GCM.seal(data, using: encryptionKey, authenticating: Data(aiIdentityKey([vault.uuidString, token]).utf8))
                .combined
        else { throw AIFailure.storage }
        return sealed.base64EncodedString()
    }

    func decode<T: Decodable>(_ value: String, token: String) throws -> T {
        guard let encryptionKey, let vault, let encrypted = Data(base64Encoded: value), encrypted.count <= 8 * 1024 * 1024 else {
            throw AIFailure.storage
        }
        do {
            let data = try AES.GCM.open(
                .init(combined: encrypted), using: encryptionKey, authenticating: Data(aiIdentityKey([vault.uuidString, token]).utf8))
            return try JSONDecoder().decode(T.self, from: data)
        } catch { throw AIFailure.storage }
    }
}

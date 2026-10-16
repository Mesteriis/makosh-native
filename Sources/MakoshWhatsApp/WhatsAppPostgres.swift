import CPostgres
import CryptoKit
import Foundation
import MakoshCore

/// Confined to WhatsAppRepository. No connection, SQL, crypto or keys reach UI.
final class WhatsAppPostgres {
  private var connection: OpaquePointer?
  private let schema: String
  private var key: SymmetricKey!
  private var vault: UUID!
  private(set) var blocked = false
  private var stateTable: String { "\"\(schema)\".whatsapp_state" }
  var chatsTable: String { "\"\(schema)\".whatsapp_chats" }
  var messagesTable: String { "\"\(schema)\".whatsapp_messages" }
  var receiptsTable: String { "\"\(schema)\".whatsapp_receipts" }
  var outboxTable: String { "\"\(schema)\".whatsapp_outbox" }
  var fileJobsTable: String { "\"\(schema)\".whatsapp_file_jobs" }
  var filesTable: String { "\"\(schema)\".whatsapp_files" }
  var preferencesTable: String { "\"\(schema)\".whatsapp_preferences" }
  var notificationsTable: String { "\"\(schema)\".whatsapp_notifications" }
  var batchesTable: String { "\"\(schema)\".whatsapp_batches" }
  var photosTable: String { "\"\(schema)\".whatsapp_photos" }
  var composeTable: String { "\"\(schema)\".whatsapp_compose" }
  var outgoingOwners = Set<UUID>()
  var batchOwners: [UUID: WhatsAppBatchLease] = [:]
  func avatarCacheKey(accountID: UUID) throws -> Data {
    guard try accounts().contains(where: { $0.id == accountID }) else { throw WhatsAppFailure.invalid }
    let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key,
      salt: Data(accountID.uuidString.utf8), info: Data("makosh-whatsapp-local-avatars-v1".utf8), outputByteCount: 32)
    return derived.withUnsafeBytes { Data($0) }
  }
  init(configuration: ContactWorkspaceConfiguration, keyProvider: (UUID, Bool) throws -> Data)
    throws
  {
    schema = configuration.schema
    guard ArchiveBackup.isValidSchemaName(schema), !configuration.connectionString.utf8.contains(0)
    else { throw WhatsAppFailure.invalid }
    connection = configuration.connectionString.withCString { dsn in
      "dbname".withCString { k in
        "connect_timeout".withCString { t in
          "5".withCString { v in
            let keys: [UnsafePointer<CChar>?] = [k, t, nil]
            let values: [UnsafePointer<CChar>?] = [dsn, v, nil]
            return keys.withUnsafeBufferPointer { ks in
              values.withUnsafeBufferPointer { vs in
                PQconnectdbParams(ks.baseAddress, vs.baseAddress, 1)
              }
            }
          }
        }
      }
    }
    guard let connection, PQstatus(connection) == CONNECTION_OK else {
      if let connection { PQfinish(connection) }
      self.connection = nil
      throw WhatsAppFailure.storage
    }
    PQsetNoticeProcessor(connection, { _, _ in }, nil)
    do {
      _ = try query("SET client_encoding TO 'UTF8'")
      _ = try query("SET statement_timeout TO '15s'")
      _ = try query("SET lock_timeout TO '5s'")
      try transaction {
        _ = try query(
          "SELECT pg_advisory_xact_lock(hashtext('makosh-whatsapp'),hashtext($1))", [schema])
        _ = try query("CREATE SCHEMA IF NOT EXISTS \"\(schema)\"")
        _ = try query(
          "CREATE TABLE IF NOT EXISTS \(stateTable)(id SMALLINT PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,vault UUID NOT NULL,ciphertext TEXT NOT NULL)"
        )
        _ = try query(
          "CREATE TABLE IF NOT EXISTS \(chatsTable)(token TEXT PRIMARY KEY,account TEXT NOT NULL,ts BIGINT NOT NULL,ciphertext TEXT NOT NULL)"
        )
        _ = try query(
          "CREATE TABLE IF NOT EXISTS \(messagesTable)(token TEXT PRIMARY KEY,account TEXT NOT NULL,chat TEXT NOT NULL,ts BIGINT NOT NULL,ciphertext TEXT NOT NULL)"
        )
        _ = try query(
          "CREATE INDEX IF NOT EXISTS whatsapp_message_page ON \(messagesTable)(account,chat,ts DESC,token DESC)"
        )
        _ = try query(
          "CREATE TABLE IF NOT EXISTS \(receiptsTable)(account TEXT NOT NULL,sequence BIGINT NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(account,sequence))"
        )
        _ = try query(
          "CREATE TABLE IF NOT EXISTS \(outboxTable)(token TEXT PRIMARY KEY,account TEXT NOT NULL,ts BIGINT NOT NULL,ciphertext TEXT NOT NULL)"
        )
        _ = try query("ALTER TABLE \(outboxTable) ADD COLUMN IF NOT EXISTS stanza_token TEXT")
        _ = try query("CREATE INDEX IF NOT EXISTS whatsapp_outbox_page ON \(outboxTable)(account,ts DESC,token DESC)")
        _ = try query("CREATE INDEX IF NOT EXISTS whatsapp_outbox_stanza ON \(outboxTable)(account,stanza_token)")
        _ = try query(
          "CREATE TABLE IF NOT EXISTS \(fileJobsTable)(token TEXT PRIMARY KEY,account TEXT NOT NULL,ciphertext TEXT NOT NULL)"
        )
        _ = try query("ALTER TABLE \(fileJobsTable) ADD COLUMN IF NOT EXISTS state TEXT")
        _ = try query("ALTER TABLE \(fileJobsTable) ADD COLUMN IF NOT EXISTS next_try BIGINT")
        _ = try query(
          "CREATE INDEX IF NOT EXISTS whatsapp_file_job_due ON \(fileJobsTable)(account,state,next_try,token)"
        )
        _ = try query(
          "CREATE TABLE IF NOT EXISTS \(filesTable)(token TEXT PRIMARY KEY,account TEXT NOT NULL,ciphertext TEXT NOT NULL)"
        )
        _ = try query("ALTER TABLE \(receiptsTable) ADD COLUMN IF NOT EXISTS ciphertext TEXT")
        _ = try query("ALTER TABLE \(receiptsTable) ADD COLUMN IF NOT EXISTS chat TEXT")
        _ = try query(
          "CREATE TABLE IF NOT EXISTS \(preferencesTable)(token TEXT PRIMARY KEY,ciphertext TEXT NOT NULL)"
        )
        _ = try query(
          "CREATE TABLE IF NOT EXISTS \(notificationsTable)(token TEXT PRIMARY KEY,account TEXT NOT NULL,sequence BIGINT NOT NULL,state TEXT NOT NULL,ciphertext TEXT NOT NULL)"
        )
        _ = try query("CREATE TABLE IF NOT EXISTS \(batchesTable)(token TEXT PRIMARY KEY,account TEXT NOT NULL,ts BIGINT NOT NULL,ciphertext TEXT NOT NULL)")
        _ = try query("CREATE TABLE IF NOT EXISTS \(photosTable)(token TEXT PRIMARY KEY,account TEXT NOT NULL,ciphertext TEXT NOT NULL)")
        _ = try query("CREATE TABLE IF NOT EXISTS \(composeTable)(token TEXT PRIMARY KEY,account TEXT NOT NULL,ciphertext TEXT NOT NULL)")
        let rows = try query(
          "SELECT version,vault,ciphertext FROM \(stateTable) WHERE id=1 FOR UPDATE")
        if let row = rows.first {
          guard row[0] == "1", let id = UUID(uuidString: row[1]) else {
            throw WhatsAppFailure.storage
          }
          vault = id
        } else {
          vault = UUID()
        }
        let raw = try keyProvider(vault, rows.isEmpty)
        guard raw.count == 32 else { throw WhatsAppFailure.key }
        key = HKDF<SHA256>.deriveKey(
          inputKeyMaterial: SymmetricKey(data: raw), salt: Data(vault.uuidString.utf8),
          info: Data("makosh-whatsapp-state-v1".utf8), outputByteCount: 32)
        if rows.isEmpty {
          _ = try query(
            "INSERT INTO \(stateTable) VALUES(1,1,$1::uuid,$2)",
            [vault.uuidString, try seal([WhatsAppAccount](), token: "state")])
        } else {
          let _: [WhatsAppAccount] = try decode(rows[0][2], token: "state")
        }
      }
    } catch {
      PQfinish(connection)
      self.connection = nil
      throw WhatsAppFailure.storage
    }
  }
  deinit { if let connection { PQfinish(connection) } }
  func transaction<T>(_ body: () throws -> T) throws -> T {
    guard !blocked else { throw WhatsAppFailure.storage }
    _ = try query("BEGIN")
    do {
      let result = try body()
      do { _ = try query("COMMIT") } catch {
        blocked = true
        throw error
      }
      return result
    } catch {
      _ = try? query("ROLLBACK")
      throw error
    }
  }
  func accounts(lock: Bool = false) throws -> [WhatsAppAccount] {
    guard
      let row = try query(
        "SELECT ciphertext FROM \(stateTable) WHERE id=1" + (lock ? " FOR UPDATE" : "")
      ).first
    else { throw WhatsAppFailure.storage }
    return try decode(row[0], token: "state")
  }
  func saveAccount(_ account: WhatsAppAccount) throws {
    guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      account.name.utf8.count <= 512
    else { throw WhatsAppFailure.invalid }
    try transaction {
      var accounts = try accounts(lock: true)
      accounts.removeAll { $0.id == account.id }
      accounts.append(account)
      _ = try query(
        "UPDATE \(stateTable) SET ciphertext=$1 WHERE id=1", [try seal(accounts, token: "state")])
    }
  }
  func token(_ fields: [String]) -> String {
    let data = (try? JSONEncoder().encode(fields)) ?? Data()
    return HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }
      .joined()
  }
  func seal<T: Encodable>(_ value: T, token: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let bytes = try AES.GCM.seal(
        encoder.encode(value), using: key,
        authenticating: Data((vault.uuidString + "|" + token).utf8)
      ).combined
    else { throw WhatsAppFailure.storage }
    return bytes.base64EncodedString()
  }
  func decode<T: Decodable>(_ value: String, token: String) throws -> T {
    guard let data = Data(base64Encoded: value) else { throw WhatsAppFailure.storage }
    do {
      return try JSONDecoder().decode(
        T.self,
        from: AES.GCM.open(
          AES.GCM.SealedBox(combined: data), using: key,
          authenticating: Data((vault.uuidString + "|" + token).utf8)))
    } catch { throw WhatsAppFailure.storage }
  }
  func query(_ sql: String, _ parameters: [String] = []) throws -> [[String]] {
    guard let connection, !parameters.contains(where: { $0.utf8.contains(0) }) else {
      throw WhatsAppFailure.storage
    }
    let pointers = parameters.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    let values = pointers.map { UnsafePointer<CChar>($0) }
    let result = values.withUnsafeBufferPointer {
      PQexecParams(connection, sql, Int32(parameters.count), nil, $0.baseAddress, nil, nil, 0)
    }
    guard let result else { throw WhatsAppFailure.storage }
    defer { PQclear(result) }
    guard PQresultStatus(result) == PGRES_TUPLES_OK || PQresultStatus(result) == PGRES_COMMAND_OK
    else { throw WhatsAppFailure.storage }
    return (0..<PQntuples(result)).map { row in
      (0..<PQnfields(result)).map { String(cString: PQgetvalue(result, row, $0)) }
    }
  }
}

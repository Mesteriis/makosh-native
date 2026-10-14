import Foundation
import CryptoKit
import CPostgres

/// Independent append-only encrypted archive. Call synchronous operations off MainActor.
public final class MessageArchiveStore {
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    private let prefix: String
    private let readOnly: Bool
    private var vault = UUID()
    private var initialized = false
    private var encryptionKey = SymmetricKey(size: .bits256)
    private var lookupKey = SymmetricKey(size: .bits256)
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    public convenience init(connectionString: String, schema: String = "makosh", readOnly: Bool = false, keyProvider: (UUID, Bool) throws -> Data) throws {
        try self.init(connectionString: connectionString, schema: schema, keyProvider: keyProvider, restoring: nil, readOnly: readOnly)
    }
    init(connectionString: String, schema: String, keyProvider: (UUID, Bool) throws -> Data, restoring: ArchiveBackupBootstrap?, readOnly: Bool = false) throws {
        let bytes = Array(schema.utf8)
        guard !bytes.isEmpty, bytes.count <= 63, (97...122).contains(bytes[0]),
              bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
              !connectionString.utf8.contains(0) else { throw MessageArchiveError.invalid }
        prefix = "\"\(schema)\"."
        self.readOnly = readOnly
        if let restoring { vault = restoring.verified.header.vaultID }
        db = connectionString.withCString { dsn in
            "dbname".withCString { k in "connect_timeout".withCString { t in "5".withCString { v in
                let keys: [UnsafePointer<CChar>?] = [k,t,nil], values: [UnsafePointer<CChar>?] = [dsn,v,nil]
                return keys.withUnsafeBufferPointer { ks in values.withUnsafeBufferPointer { vs in PQconnectdbParams(ks.baseAddress,vs.baseAddress,1) } }
            } } }
        }
        guard let db, PQstatus(db) == CONNECTION_OK else {
            if let db { PQfinish(db) }; self.db = nil; throw MessageArchiveError.database
        }
        PQsetNoticeProcessor(db, { _, _ in }, nil)
        do {
            _ = try query("SET client_encoding TO 'UTF8'")
            _ = try query("SET statement_timeout TO '15s'")
            _ = try query("SET lock_timeout TO '5s'")
            if readOnly { _ = try query("SET default_transaction_read_only TO on") }
            try transaction {
                if readOnly {
                    let meta = try metadata()
                    guard let uuid = UUID(uuidString: meta[1]) else { throw MessageArchiveError.integrity }
                    vault = uuid
                    let raw: Data
                    do { raw = try keyProvider(vault, false) } catch { throw MessageArchiveError.keyUnavailable }
                    guard raw.count == 32 else { throw MessageArchiveError.keyUnavailable }
                    encryptionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(vault.uuidString.utf8), info: Data("makosh-archive-aes-v1".utf8), outputByteCount: 32)
                    lookupKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(vault.uuidString.utf8), info: Data("makosh-archive-hmac-v1".utf8), outputByteCount: 32)
                    guard !meta[2].isEmpty, let check = try? open(meta[2], aad: binding("key",0)), check == Data("archive-key-check-v1".utf8) else { throw MessageArchiveError.keyUnavailable }
                    return
                }
                _ = try query("SELECT pg_advisory_xact_lock(hashtext('makosh-archive'),hashtext($1))", [schema])
                if restoring != nil {
                    guard try query("SELECT 1 FROM pg_namespace WHERE nspname=$1", [schema]).isEmpty else { throw ArchiveBackupError.conflict }
                    _ = try query("CREATE SCHEMA \"\(schema)\"")
                } else {
                    _ = try query("CREATE SCHEMA IF NOT EXISTS \"\(schema)\"")
                }
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)archive_metadata (id SMALLINT PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, vault UUID NOT NULL, key_check TEXT)")
                let inserted = try query("INSERT INTO \(prefix)archive_metadata VALUES (1,1,$1::uuid,NULL) ON CONFLICT DO NOTHING RETURNING vault", [vault.uuidString])
                let meta = try metadata()
                guard let uuid = UUID(uuidString: meta[1]) else { throw MessageArchiveError.integrity }; vault = uuid
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)archive_events (sequence BIGSERIAL PRIMARY KEY, observation UUID NOT NULL UNIQUE, account_token TEXT NOT NULL, stream_token TEXT NOT NULL, message_token TEXT NOT NULL, event_digest TEXT NOT NULL, ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)archive_receipts (observation UUID PRIMARY KEY, digest TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)archive_file_events (sequence BIGSERIAL PRIMARY KEY, object UUID NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','stored')), attachment_token TEXT NOT NULL, ciphertext TEXT NOT NULL, UNIQUE(object,state))")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)archive_conversation_file_policy (stream_token TEXT PRIMARY KEY, ciphertext TEXT NOT NULL)")
                _ = try query("CREATE TABLE IF NOT EXISTS \(prefix)archive_storage_aliases (source_storage TEXT NOT NULL, destination_storage TEXT NOT NULL, ciphertext TEXT NOT NULL, PRIMARY KEY(source_storage,destination_storage), CHECK(source_storage<>destination_storage))")
                let populated = try query("SELECT 1 FROM \(prefix)archive_events LIMIT 1")
                let mayCreate = !inserted.isEmpty && meta[2].isEmpty && populated.isEmpty
                let raw: Data
                do { raw = try keyProvider(vault, mayCreate) } catch { throw MessageArchiveError.keyUnavailable }
                guard raw.count == 32 else { throw MessageArchiveError.keyUnavailable }
                encryptionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(vault.uuidString.utf8), info: Data("makosh-archive-aes-v1".utf8), outputByteCount: 32)
                lookupKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(vault.uuidString.utf8), info: Data("makosh-archive-hmac-v1".utf8), outputByteCount: 32)
                if mayCreate {
                    _ = try query("UPDATE \(prefix)archive_metadata SET key_check=$1 WHERE id=1", [try seal(Data("archive-key-check-v1".utf8), aad: binding("key", 0))])
                } else {
                    guard !meta[2].isEmpty, let check = try? open(meta[2], aad: binding("key",0)), check == Data("archive-key-check-v1".utf8) else { throw MessageArchiveError.keyUnavailable }
                }
                _ = try query("CREATE OR REPLACE FUNCTION \(prefix)archive_no_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'append only'; END $$")
                _ = try query("DROP TRIGGER IF EXISTS archive_no_rewrite ON \(prefix)archive_events")
                _ = try query("CREATE TRIGGER archive_no_rewrite BEFORE UPDATE OR DELETE OR TRUNCATE ON \(prefix)archive_events FOR EACH STATEMENT EXECUTE FUNCTION \(prefix)archive_no_rewrite()")
                _ = try query("DROP TRIGGER IF EXISTS archive_no_rewrite ON \(prefix)archive_receipts")
                _ = try query("CREATE TRIGGER archive_no_rewrite BEFORE UPDATE OR DELETE OR TRUNCATE ON \(prefix)archive_receipts FOR EACH STATEMENT EXECUTE FUNCTION \(prefix)archive_no_rewrite()")
                _ = try query("DROP TRIGGER IF EXISTS archive_no_rewrite ON \(prefix)archive_file_events")
                _ = try query("CREATE TRIGGER archive_no_rewrite BEFORE UPDATE OR DELETE OR TRUNCATE ON \(prefix)archive_file_events FOR EACH STATEMENT EXECUTE FUNCTION \(prefix)archive_no_rewrite()")
                _ = try query("DROP TRIGGER IF EXISTS archive_no_rewrite ON \(prefix)archive_storage_aliases")
                _ = try query("CREATE TRIGGER archive_no_rewrite BEFORE UPDATE OR DELETE OR TRUNCATE ON \(prefix)archive_storage_aliases FOR EACH STATEMENT EXECUTE FUNCTION \(prefix)archive_no_rewrite()")
                _ = try query("CREATE INDEX IF NOT EXISTS archive_file_attachment ON \(prefix)archive_file_events(attachment_token,sequence DESC)")
                _ = try query("CREATE INDEX IF NOT EXISTS archive_stream_sequence ON \(prefix)archive_events(stream_token,sequence DESC)")
                if let restoring { try restoreBackupRows(restoring) }
            }
            initialized = true
        } catch { PQfinish(db); self.db = nil; throw error }
    }
    deinit { if let db { PQfinish(db) } }

    private struct ConversationFilePolicy: Codable {
        let service: String
        let accountID: String
        let conversationID: String
        let enabled: Bool
    }
    private func conversationPolicyToken(_ identity: MessageArchiveIdentity) throws -> String {
        let scope = [identity.service,identity.accountID,identity.conversationID]
        guard scope.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw MessageArchiveError.invalid }
        return token(scope)
    }
    public func conversationFileSavingEnabled(identity: MessageArchiveIdentity, defaultEnabled: Bool) throws -> Bool {
        try explicitConversationFileSavingEnabled(identity: identity) ?? defaultEnabled
    }
    public func explicitConversationFileSavingEnabled(identity: MessageArchiveIdentity) throws -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            _ = try metadata()
            let stream = try conversationPolicyToken(identity)
            let rows = try query("SELECT CASE WHEN octet_length(ciphertext)<=32768 THEN ciphertext ELSE NULL END FROM \(prefix)archive_conversation_file_policy WHERE stream_token=$1", [stream])
            guard let row = rows.first else { return nil }
            guard rows.count == 1 else { throw MessageArchiveError.integrity }
            let policy: ConversationFilePolicy
            do {
                policy = try JSONDecoder().decode(ConversationFilePolicy.self,
                    from: open(row[0],aad: binding("conversation-file-policy-\(stream)",0)))
            } catch { throw MessageArchiveError.integrity }
            guard policy.service.utf8.elementsEqual(identity.service.utf8),
                  policy.accountID.utf8.elementsEqual(identity.accountID.utf8),
                  policy.conversationID.utf8.elementsEqual(identity.conversationID.utf8) else { throw MessageArchiveError.integrity }
            return policy.enabled
        }
    }
    public func setConversationFileSavingEnabled(identity: MessageArchiveIdentity, enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            _ = try metadata()
            let stream = try conversationPolicyToken(identity)
            let payload = try encode(ConversationFilePolicy(service: identity.service,accountID: identity.accountID,
                conversationID: identity.conversationID,enabled: enabled))
            guard payload.count <= 16384 else { throw MessageArchiveError.invalid }
            _ = try query("INSERT INTO \(prefix)archive_conversation_file_policy(stream_token,ciphertext) VALUES($1,$2) ON CONFLICT(stream_token) DO UPDATE SET ciphertext=EXCLUDED.ciphertext",
                [stream,try seal(payload,aad: binding("conversation-file-policy-\(stream)",0))])
        }
    }

    public func fileVault() throws -> ArchiveFileVault {
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            _ = try metadata()
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: encryptionKey, salt: Data(vault.uuidString.utf8), info: Data("makosh-file-vault-v1".utf8), outputByteCount: 32)
            return ArchiveFileVault(id: vault, key: key.withUnsafeBytes { Data($0) })
        }
    }

    @discardableResult public func appendFile(_ record: ArchiveFileRecord) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            _ = try metadata()
            try record.validate(vaultID: vault)
            let i = record.identity
            let payload = try encode(record)
            guard payload.count <= 16384 else { throw MessageArchiveError.invalid }
            let aad = binding("file-\(record.id.uuidString)-\(record.state.rawValue)",0)
            let existing = try query("SELECT ciphertext FROM \(prefix)archive_file_events WHERE object=$1::uuid AND state=$2", [record.id.uuidString,record.state.rawValue])
            if let prior = existing.first {
                guard try open(prior[0],aad: aad) == payload else { throw MessageArchiveError.integrity }
                return false
            }
            _ = try query("INSERT INTO \(prefix)archive_file_events(object,state,attachment_token,ciphertext) VALUES($1::uuid,$2,$3,$4)", [record.id.uuidString,record.state.rawValue,token([i.service,i.accountID,i.conversationID,i.messageID,record.attachment.id]),try seal(payload,aad: aad)])
            return true
        }
    }

    public func files(identity: MessageArchiveIdentity, attachmentID: String) throws -> [ArchiveFileRecord] {
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            _ = try metadata()
            let lookup = token([identity.service,identity.accountID,identity.conversationID,identity.messageID,attachmentID])
            let rows = try query("SELECT object,state,ciphertext FROM \(prefix)archive_file_events WHERE attachment_token=$1 AND state='stored' ORDER BY sequence DESC LIMIT 100", [lookup])
            return try rows.map { row in
                let record: ArchiveFileRecord
                do { record = try JSONDecoder().decode(ArchiveFileRecord.self, from: open(row[2],aad: binding("file-\(row[0].uppercased())-\(row[1])",0))) }
                catch { throw MessageArchiveError.integrity }
                guard record.identity == identity, record.attachment.id.utf8.elementsEqual(attachmentID.utf8), record.id.uuidString.lowercased() == row[0], record.state == .stored else { throw MessageArchiveError.integrity }
                return record
            }
        }
    }

    public func append(_ observations: [MessageArchiveObservation]) throws -> Int {
        guard observations.count <= 1000 else { throw MessageArchiveError.invalid }
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            _ = try metadata()
            var inserted = 0
            for observation in observations {
                let identity = observation.identity
                guard [identity.service, identity.accountID, identity.conversationID, identity.messageID]
                    .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }), observation.observedAt.timeIntervalSince1970.isFinite else {
                    throw MessageArchiveError.invalid
                }
                let account = token([identity.service, identity.accountID])
                let stream = token([identity.service, identity.accountID, identity.conversationID])
                let message = token([identity.service, identity.accountID, identity.conversationID, identity.messageID])
                let payload = try encode(observation)
                guard payload.count <= 4 * 1024 * 1024 else { throw MessageArchiveError.invalid }
                let receipt = mac(payload)
                let prior = try query("SELECT digest FROM \(prefix)archive_receipts WHERE observation=$1::uuid", [observation.id.uuidString])
                if let row = prior.first {
                    guard row[0] == receipt else { throw MessageArchiveError.integrity }
                    continue
                }
                _ = try query("INSERT INTO \(prefix)archive_receipts VALUES($1::uuid,$2)", [observation.id.uuidString,receipt])
                let digest = mac(try encode(observation.event))
                let latest = try query("SELECT event_digest FROM \(prefix)archive_events WHERE message_token=$1 ORDER BY sequence DESC LIMIT 1", [message])
                if latest.first?.first == digest { continue }
                let next = try query("SELECT nextval(pg_get_serial_sequence($1,'sequence'))", [prefix + "archive_events"])
                guard let value = next.first?.first, let sequence = Int64(value) else { throw MessageArchiveError.database }
                let cipher = try seal(payload, aad: binding(message,sequence))
                _ = try query("INSERT INTO \(prefix)archive_events(sequence,observation,account_token,stream_token,message_token,event_digest,ciphertext) VALUES($1::bigint,$2::uuid,$3,$4,$5,$6,$7)", [value,observation.id.uuidString,account,stream,message,digest,cipher])
                inserted += 1
            }
            return inserted
        }
    }
    public func records(before: Int64? = nil, limit: Int = 100) throws -> [MessageArchiveRecord] {
        try readRecords(stream: nil, before: before, limit: limit)
    }
    public func records(service: String, accountID: String, conversationID: String, before: Int64? = nil, limit: Int = 100) throws -> [MessageArchiveRecord] {
        lock.lock(); defer { lock.unlock() }
        return try readRecords(stream: token([service,accountID,conversationID]), before: before, limit: limit)
    }
    private func readRecords(stream: String?, before: Int64?, limit: Int) throws -> [MessageArchiveRecord] {
        guard (1...200).contains(limit) else { throw MessageArchiveError.invalid }
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            _ = try metadata()
            let rows = try query("SELECT sequence,message_token,ciphertext FROM \(prefix)archive_events WHERE ($1::text IS NULL OR stream_token=$1) AND ($2::bigint IS NULL OR sequence<$2::bigint) ORDER BY sequence DESC LIMIT $3::int", [stream,before.map(String.init),String(limit)])
            return try rows.map { row in
                guard let sequence = Int64(row[0]) else { throw MessageArchiveError.integrity }
                let observation: MessageArchiveObservation
                do { observation = try JSONDecoder().decode(MessageArchiveObservation.self, from: open(row[2], aad: binding(row[1],sequence))) }
                catch { throw MessageArchiveError.integrity }
                let i = observation.identity
                guard (stream == nil || token([i.service,i.accountID,i.conversationID]) == stream),
                      token([i.service,i.accountID,i.conversationID,i.messageID]) == row[1] else { throw MessageArchiveError.integrity }
                return MessageArchiveRecord(sequence: sequence, observation: observation)
            }
        }
    }
    private func metadata() throws -> [String] {
        let rows = try query("SELECT version,vault,key_check FROM \(prefix)archive_metadata WHERE id=1" + (readOnly ? "" : " FOR UPDATE"))
        guard let row = rows.first, rows.count == 1 else { throw MessageArchiveError.integrity }
        guard row[0] == "1" else { throw MessageArchiveError.unsupportedSchema }
        if initialized {
            guard row[1].lowercased() == vault.uuidString.lowercased(),
                  let check = try? open(row[2], aad: binding("key",0)), check == Data("archive-key-check-v1".utf8) else { throw MessageArchiveError.integrity }
        }
        return row
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try encoder.encode(value) } catch { throw MessageArchiveError.invalid }
    }
    private func token(_ values: [String]) -> String { mac(values.reduce(into: Data()) { data,value in data.append(Data("\(value.utf8.count):".utf8)); data.append(Data(value.utf8)) }) }
    private func mac(_ data: Data) -> String { Data(HMAC<SHA256>.authenticationCode(for: data, using: lookupKey)).base64EncodedString() }
    private func binding(_ token: String, _ sequence: Int64) -> Data { Data("\(vault.uuidString)|1|\(token)|\(sequence)".utf8) }
    private func seal(_ data: Data, aad: Data) throws -> String {
        guard let combined = try AES.GCM.seal(data, using: encryptionKey, authenticating: aad).combined else { throw MessageArchiveError.integrity }
        return combined.base64EncodedString()
    }
    private func open(_ text: String, aad: Data) throws -> Data {
        guard let data = Data(base64Encoded: text) else { throw MessageArchiveError.integrity }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encryptionKey, authenticating: aad)
    }
    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        _ = try query("BEGIN")
        do { let result = try operation(); _ = try query("COMMIT"); return result }
        catch { _ = try? query("ROLLBACK"); throw error }
    }
    private func query(_ sql: String, _ parameters: [String?] = []) throws -> [[String]] {
        let allocated = parameters.map { $0.flatMap { strdup($0) } }
        defer { allocated.forEach { free($0) } }
        let pointers = allocated.map { $0.map { UnsafePointer<CChar>($0) } }
        let result = pointers.withUnsafeBufferPointer { values in PQexecParams(db, sql, Int32(values.count), nil, values.baseAddress, nil, nil, 0) }
        guard let result else { throw MessageArchiveError.database }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_COMMAND_OK || PQresultStatus(result) == PGRES_TUPLES_OK else { throw MessageArchiveError.database }
        return (0..<PQntuples(result)).map { row in (0..<PQnfields(result)).map { col in PQgetisnull(result,row,col) == 1 ? "" : String(cString: PQgetvalue(result,row,col)) } }
    }
}

// A bounded MVCC snapshot: unrelated contacts, sessions and credentials are never selected.
extension MessageArchiveStore {
    public func disabledConversationFilePolicies() throws -> [MessageArchiveIdentity] {
        lock.lock(); defer { lock.unlock() }
        _ = try query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        do {
            let rows = try query("SELECT version,vault,key_check FROM \(prefix)archive_metadata WHERE id=1")
            guard let meta = rows.first, rows.count == 1, meta[0] == "1", meta[1] == vault.uuidString.lowercased(),
                  try open(meta[2], aad: binding("key",0)) == Data("archive-key-check-v1".utf8) else { throw MessageArchiveError.integrity }
            _ = try query("DECLARE makosh_policy_cursor NO SCROLL CURSOR FOR SELECT stream_token,CASE WHEN octet_length(ciphertext)<=32768 THEN ciphertext ELSE NULL END FROM \(prefix)archive_conversation_file_policy ORDER BY stream_token COLLATE \"C\"")
            var result: [MessageArchiveIdentity] = [], scanned = 0, retained = 0
            while true {
                try Task.checkCancellation()
                let rows = try query("FETCH FORWARD 16 FROM makosh_policy_cursor")
                if rows.isEmpty { break }
                for row in rows {
                    scanned += 1
                    guard scanned <= ArchiveBackupLimits.objects, row[0].utf8.count <= 256 else { throw ArchiveBackupError.invalid }
                    let payload = try open(row[1], aad: binding("conversation-file-policy-\(row[0])",0))
                    guard payload.count <= 16384 else { throw MessageArchiveError.integrity }
                    let policy = try JSONDecoder().decode(ConversationFilePolicy.self, from: payload)
                    let identity = MessageArchiveIdentity(service: policy.service, accountID: policy.accountID, conversationID: policy.conversationID, messageID: "archive-policy")
                    guard try conversationPolicyToken(identity) == row[0] else { throw MessageArchiveError.integrity }
                    if !policy.enabled {
                        retained += payload.count + 128
                        guard retained <= ArchiveBackupLimits.metadata else { throw ArchiveBackupError.invalid }
                        result.append(identity)
                    }
                }
            }
            _ = try query("CLOSE makosh_policy_cursor"); _ = try query("COMMIT"); return result
        } catch { _ = try? query("ROLLBACK"); throw error }
    }
    func acceptsStorageAlias(source: String, destination: String) throws -> Bool {
        guard ArchiveFileRecord.validHash(source), ArchiveFileRecord.validHash(destination) else { throw MessageArchiveError.invalid }
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            _ = try metadata()
            let rows = try query("SELECT ciphertext FROM \(prefix)archive_storage_aliases WHERE source_storage=$1 AND destination_storage=$2", [source, destination])
            guard let row = rows.first else { return false }
            let alias = try JSONDecoder().decode(ArchiveBackupStorageAlias.self, from: open(row[0], aad: binding("storage-alias-\(source)-\(destination)",0)))
            guard rows.count == 1, alias.vaultID == vault, alias.source == source, alias.destination == destination else { throw MessageArchiveError.integrity }
            return true
        }
    }
    private func restoreBackupRows(_ bootstrap: ArchiveBackupBootstrap) throws {
        let header = bootstrap.verified.header
        guard header.vaultID == vault else { throw ArchiveBackupError.integrity }
        let validator = try ArchiveBackupRowValidator(vaultID: vault, rootKey: header.rootKey)
        let reader = try ArchiveBackupRecordReader(bootstrap.verified.database)
        while let row = try reader.next() {
            try Task.checkCancellation(); try validator.accept(row)
            if row.table == .metadata { continue }
            let columns = row.table.columns.joined(separator: ",")
            let placeholders = (1...row.values.count).map { "$" + String($0) }.joined(separator: ",")
            _ = try query("INSERT INTO \(prefix)\(row.table.rawValue)(\(columns)) VALUES(\(placeholders))", row.values.map(Optional.some))
        }
        _ = try validator.finish()
        guard validator.counts == header.counts else { throw ArchiveBackupError.integrity }
        for table in [ArchiveBackupTable.events, .files] {
            _ = try query("SELECT setval(pg_get_serial_sequence($1,'sequence'),GREATEST(COALESCE((SELECT max(sequence) FROM \(prefix)\(table.rawValue)),0),1),(SELECT count(*)>0 FROM \(prefix)\(table.rawValue)))", [prefix + table.rawValue])
        }
        if let destination = bootstrap.destinationStorageID {
            for source in Set(bootstrap.verified.objects.map { $0.record.storageID }).sorted() where source != destination {
                let alias = ArchiveBackupStorageAlias(vaultID: vault, source: source, destination: destination)
                let token = "storage-alias-\(source)-\(destination)", payload = try encode(alias)
                let rows = try query("SELECT ciphertext FROM \(prefix)archive_storage_aliases WHERE source_storage=$1 AND destination_storage=$2", [source, destination])
                if let row = rows.first {
                    guard try open(row[0], aad: binding(token,0)) == payload else { throw MessageArchiveError.integrity }
                } else {
                    _ = try query("INSERT INTO \(prefix)archive_storage_aliases VALUES($1,$2,$3)", [source, destination, try seal(payload, aad: binding(token,0))])
                }
            }
        }
        for identity in bootstrap.disabledPolicies {
            let stream = try conversationPolicyToken(identity)
            let policy = ConversationFilePolicy(service: identity.service, accountID: identity.accountID, conversationID: identity.conversationID, enabled: false)
            _ = try query("INSERT INTO \(prefix)archive_conversation_file_policy VALUES($1,$2) ON CONFLICT(stream_token) DO UPDATE SET ciphertext=EXCLUDED.ciphertext", [stream, try seal(encode(policy), aad: binding("conversation-file-policy-\(stream)",0))])
        }
        try Task.checkCancellation()
        try bootstrap.installKey(vault, header.rootKey)
    }
    func writeBackupSnapshot(_ receive: (ArchiveBackupRow) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        do {
            for table in ArchiveBackupTable.allCases {
                if table == .aliases {
                    let present = try query("SELECT to_regclass($1)::text", [prefix + table.rawValue])
                    if present.first?.first?.isEmpty != false { continue }
                }
                let columns = table.columns.map { column in
                    let cap = ["ciphertext", "key_check"].contains(column) ? 6 * 1024 * 1024 : 2048
                    return "CASE WHEN octet_length(\(column)::text)<=\(cap) THEN \(column)::text ELSE NULL END"
                }.joined(separator: ",")
                _ = try query("DECLARE makosh_backup_cursor NO SCROLL CURSOR FOR SELECT \(columns) FROM \(prefix)\(table.rawValue) ORDER BY \(table.order)")
                while true {
                    try Task.checkCancellation()
                    let rows = try query("FETCH FORWARD 16 FROM makosh_backup_cursor")
                    if rows.isEmpty { break }
                    for values in rows { try receive(.init(table: table, values: values)) }
                }
                _ = try query("CLOSE makosh_backup_cursor")
            }
            _ = try query("COMMIT")
        } catch { _ = try? query("ROLLBACK"); throw error }
    }
}

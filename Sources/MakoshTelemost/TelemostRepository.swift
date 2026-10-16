import Foundation
import CryptoKit
import MakoshCore

public actor TelemostRepository {
    let keyProvider: @Sendable (UUID, Bool) throws -> Data
    var database: TelemostPostgres?
    var leases: [UUID: (TelemostLease, TelemostPGConnection)] = [:]
    public init(keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open) { self.keyProvider = keyProvider }
    public func open(configuration: ContactWorkspaceConfiguration) throws {
        if let database {
            guard database.configuration.schema == configuration.schema,
                  database.configuration.archiveSchema == configuration.archiveSchema,
                  database.configuration.connectionString == configuration.connectionString else { throw TelemostFailure.invalidConfiguration }
            return
        }
        let db = try TelemostPostgres(configuration: configuration); try db.open(keyProvider: keyProvider); database = db
        do { try recoverDispatching() } catch { close(); throw error }
    }
    public func close() {
        for (_, connection) in leases.values { connection.close() }; leases.removeAll()
        database?.close(); database = nil
    }
    func db() throws -> TelemostPostgres { guard let database, !database.blocked else { throw TelemostFailure.storage }; return database }
    func owner(_ accountID: UUID?) throws -> String {
        let db = try db(); guard let area = db.localArea else { throw TelemostFailure.storage }
        return try db.token(["owner", accountID?.uuidString ?? "local:" + area.uuidString])
    }
    func record<T: Decodable>(_ type: T.Type, kind: String, key: String) throws -> T? {
        let db = try db(), token = try db.token([kind, key])
        guard let row = try db.query("SELECT owner,status,ciphertext FROM \(db.prefix)telemost_records WHERE token=$1 AND kind=$2", [token, kind]).first else { return nil }
        return try db.decode(row[2], token: "record:" + token + ":" + row[0] + ":" + row[1])
    }
    func records<T: Decodable>(_ type: T.Type, kind: String, owner: String? = nil, status: String? = nil, limit: Int = 500) throws -> [T] {
        let db = try db()
        var sql = "SELECT token,owner,status,ciphertext FROM \(db.prefix)telemost_records WHERE kind=$1"
        var parameters = [kind]
        if let owner { parameters.append(owner); sql += " AND owner=$\(parameters.count)" }
        if let status { parameters.append(status); sql += " AND status=$\(parameters.count)" }
        sql += " ORDER BY sequence DESC LIMIT \(max(1, min(limit, 1000)))"
        return try db.query(sql, parameters).map { try db.decode($0[3], token: "record:" + $0[0] + ":" + $0[1] + ":" + $0[2]) }
    }
    func put<T: Codable>(_ value: T, kind: String, key: String, owner: String, status: String = "", versioned: Bool = true) throws {
        let db = try db(), token = try db.token([kind, key])
        if let existing: T = try record(T.self, kind: kind, key: key),
           try db.encoded(existing) == db.encoded(value) { return }
        let ciphertext = try db.seal(value, token: "record:" + token + ":" + owner + ":" + status)
        try db.query("INSERT INTO \(db.prefix)telemost_records(token,kind,owner,status,ciphertext) VALUES($1,$2,$3,$4,$5) ON CONFLICT(token) DO UPDATE SET owner=excluded.owner,status=excluded.status,ciphertext=excluded.ciphertext,sequence=excluded.sequence",
                     [token, kind, owner, status, ciphertext])
        if versioned {
            guard let sequence = try db.query("SELECT nextval(pg_get_serial_sequence($1,'sequence'))", [db.prefix + "telemost_versions"]).first?.first else { throw TelemostFailure.storage }
            let sealed = try db.seal(value, token: "version:" + token + ":" + owner + ":" + sequence)
            try db.query("INSERT INTO \(db.prefix)telemost_versions(sequence,token,kind,owner,ciphertext) VALUES($1::bigint,$2,$3,$4,$5)", [sequence, token, kind, owner, sealed])
        }
    }
    public func saveAccount(_ account: TelemostAccount) throws {
        let allowed = CharacterSet(charactersIn: "abcdefABCDEF0123456789")
        guard account.clientID.utf8.count == 32, account.clientID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, account.name.utf8.count <= 1024,
              account.callbackURL.absoluteString == "org.makosh.desktop.telemost://oauth/callback",
              account.capabilities.contains(.read),
              account.principal.map({ $0.clientID.utf8.elementsEqual(account.clientID.utf8) }) ?? true else { throw TelemostFailure.invalidConfiguration }
        let db = try db()
        try db.transaction {
            if let previous: TelemostAccount = try record(TelemostAccount.self, kind: "account", key: account.id.uuidString) {
                guard previous.clientID.utf8.elementsEqual(account.clientID.utf8), previous.callbackURL == account.callbackURL,
                      previous.principal.map({ account.principal.map($0.sameSource) ?? false }) ?? true else { throw TelemostFailure.conflict }
            }
            try put(account, kind: "account", key: account.id.uuidString, owner: owner(account.id), versioned: false)
        }
    }
    public func account(id: UUID) throws -> TelemostAccount {
        guard let value = try record(TelemostAccount.self, kind: "account", key: id.uuidString), value.id == id else { throw TelemostFailure.missing }
        return value
    }
    public func accounts() throws -> [TelemostAccount] { try records(TelemostAccount.self, kind: "account") }
    public func meeting(id: UUID) throws -> TelemostLocalMeeting {
        guard let value = try record(TelemostLocalMeeting.self, kind: "local", key: id.uuidString), value.id == id else { throw TelemostFailure.missing }
        return value
    }
    func matchingMeeting(accountID: UUID?, url: TelemostMeetingURL) throws -> TelemostLocalMeeting? {
        let db = try db(), key = try db.token(["link", try owner(accountID), url.url.absoluteString])
        guard let id: UUID = try record(UUID.self, kind: "link", key: key) else { return nil }
        let value = try meeting(id: id)
        guard value.accountID == accountID, value.validatedURL == url else { throw TelemostFailure.storage }; return value
    }
    public func saveLocal(_ meeting: TelemostLocalMeeting) throws {
        guard meeting.localTitle.utf8.count <= 4096, meeting.notes.utf8.count <= 64 * 1024 else { throw TelemostFailure.invalidConfiguration }
        let db = try db()
        try db.transaction {
            if let id = meeting.accountID { _ = try account(id: id) }
            if let existing: TelemostLocalMeeting = try record(TelemostLocalMeeting.self, kind: "local", key: meeting.id.uuidString) {
                guard existing.accountID == meeting.accountID, existing.validatedURL == meeting.validatedURL,
                      existing.updatedAt == meeting.updatedAt else { throw TelemostFailure.conflict }
                var value = existing
                value.localTitle = meeting.localTitle; value.notes = meeting.notes; value.starred = meeting.starred; value.hidden = meeting.hidden
                if value != existing { value.updatedAt = Date() }
                try put(value, kind: "local", key: value.id.uuidString, owner: owner(value.accountID))
            } else {
                guard try matchingMeeting(accountID: meeting.accountID, url: meeting.validatedURL) == nil,
                      meeting.conference == nil, meeting.cohosts.isEmpty else { throw TelemostFailure.conflict }
                try put(meeting, kind: "local", key: meeting.id.uuidString, owner: owner(meeting.accountID))
                let link = try db.token(["link", try owner(meeting.accountID), meeting.validatedURL.url.absoluteString])
                try put(meeting.id, kind: "link", key: link, owner: owner(meeting.accountID), versioned: false)
            }
        }
    }
    public func addLink(_ url: TelemostMeetingURL, accountID: UUID?) throws -> UUID {
        if let existing = try matchingMeeting(accountID: accountID, url: url) { return existing.id }
        let value = TelemostLocalMeeting(accountID: accountID, validatedURL: url)
        do { try saveLocal(value); return value.id }
        catch {
            if let existing = try matchingMeeting(accountID: accountID, url: url) { return existing.id }
            throw error
        }
    }
    public func retain(_ conference: TelemostConference) throws {
        let db = try db(); try db.transaction { try retainInTransaction(conference) }
    }
    func retainInTransaction(_ conference: TelemostConference) throws {
        let db = try db()
        guard conference.joinURL.conferenceID.utf8.elementsEqual(conference.scope.conferenceID.utf8),
              conference.retainedJSON.count <= 4 * 1024 * 1024 else { throw TelemostFailure.invalidResponse }
            _ = try account(id: conference.scope.accountID)
            let owner = try owner(conference.scope.accountID)
            let current: TelemostConference? = try record(TelemostConference.self, kind: "conference", key: conference.scope.storageKey)
            let changed = current?.retainedJSON != conference.retainedJSON || current?.waitingRoomRaw != conference.waitingRoomRaw
            if changed { try put(conference, kind: "conference", key: conference.scope.storageKey, owner: owner) }
            var local = try matchingMeeting(accountID: conference.scope.accountID, url: conference.joinURL)
                ?? TelemostLocalMeeting(accountID: conference.scope.accountID, validatedURL: conference.joinURL)
            if changed || local.conference == nil || local.unavailable {
                local.conference = changed ? conference : current; local.unavailable = false; local.updatedAt = Date()
                try put(local, kind: "local", key: local.id.uuidString, owner: owner)
                let link = try db.token(["link", owner, local.validatedURL.url.absoluteString])
                try put(local.id, kind: "link", key: link, owner: owner, versioned: false)
            }
    }
    public func markUnavailable(scope: TelemostScope) throws {
        let url = try TelemostMeetingURL("https://telemost.yandex.ru/j/" + scope.conferenceID)
        guard var value = try matchingMeeting(accountID: scope.accountID, url: url) else { return }
        value.unavailable = true
        let db = try db()
        try db.transaction { try put(value, kind: "local", key: value.id.uuidString, owner: owner(value.accountID)) }
    }
    public func history(scope: TelemostScope, before: Int64?, limit: Int) throws -> [TelemostConference] {
        let db = try db(); guard limit > 0, limit <= 100 else { throw TelemostFailure.invalidConfiguration }
        let key = try db.token(["conference", scope.storageKey]), owner = try owner(scope.accountID)
        let rows = try db.query("SELECT sequence,ciphertext FROM \(db.prefix)telemost_versions WHERE kind='conference' AND token=$1 AND owner=$2 AND sequence<$3::bigint ORDER BY sequence DESC LIMIT \(limit)",
                                [key, owner, String(before ?? Int64.max)])
        return try rows.map { row in
            let value: TelemostConference = try db.decode(row[1], token: "version:" + key + ":" + owner + ":" + row[0])
            guard value.scope == scope else { throw TelemostFailure.storage }; return value
        }
    }
    public func versions(meetingID: UUID, before: Int64? = nil, limit: Int = 50) throws -> [TelemostRetainedVersion] {
        let local = try meeting(id: meetingID), db = try db(), owner = try owner(local.accountID)
        let localKey = try db.token(["local", meetingID.uuidString])
        let confKey = try local.scope.map { try db.token(["conference", $0.storageKey]) } ?? ""
        return try db.query("SELECT sequence,token,kind,ciphertext FROM \(db.prefix)telemost_versions WHERE owner=$1 AND (token=$2 OR token=$3) AND sequence<$4::bigint ORDER BY sequence DESC LIMIT \(max(1,min(limit,100)))",
                            [owner, localKey, confKey, String(before ?? Int64.max)]).map { row in
            let payload: Data
            if row[2] == "local" { let value: TelemostLocalMeeting = try db.decode(row[3], token: "version:" + row[1] + ":" + owner + ":" + row[0]); payload = try db.encoded(value) }
            else { let value: TelemostConference = try db.decode(row[3], token: "version:" + row[1] + ":" + owner + ":" + row[0]); payload = try db.encoded(value) }
            guard let sequence = Int64(row[0]) else { throw TelemostFailure.storage }
            return .init(sequence: sequence, kind: row[2], payload: payload)
        }
    }
    public func page(accountID: UUID?, query: String, before: TelemostHistoryCursor?, limit: Int) throws -> TelemostMeetingPage {
        let db = try db(), owner = try owner(accountID)
        guard limit > 0, limit <= 100, query.utf8.count <= 4096,
              before.map({ $0.owner == owner && $0.query.utf8.elementsEqual(query.utf8) }) ?? true else { throw TelemostFailure.invalidConfiguration }
        let upper = try before?.upper ?? Int64(db.query("SELECT COALESCE(max(sequence),0) FROM \(db.prefix)telemost_versions").first?.first ?? "0") ?? 0
        var boundary = before?.before ?? Int64.max, found: [(TelemostLocalMeeting, Int64)] = [], exhausted = false
        for _ in 0..<20 {
            let rows = try db.query("SELECT sequence,token,ciphertext FROM (SELECT DISTINCT ON(token) sequence,token,ciphertext FROM \(db.prefix)telemost_versions WHERE kind='local' AND owner=$1 AND sequence<=$2::bigint ORDER BY token,sequence DESC) page WHERE sequence<$3::bigint ORDER BY sequence DESC LIMIT 100",
                                    [owner, String(upper), String(boundary)])
            for row in rows {
                guard let sequence = Int64(row[0]) else { throw TelemostFailure.storage }
                let value: TelemostLocalMeeting = try db.decode(row[2], token: "version:" + row[1] + ":" + owner + ":" + row[0])
                guard value.accountID == accountID else { throw TelemostFailure.storage }
                boundary = sequence
                if (query.isEmpty || [value.localTitle, value.notes, value.validatedURL.url.absoluteString].contains(where: { $0.localizedCaseInsensitiveContains(query) })) { found.append((value, sequence)) }
                if found.count > limit { break }
            }
            if found.count > limit { break }
            if rows.count < 100 { exhausted = true; break }
        }
        let values = Array(found.prefix(limit))
        let next: TelemostHistoryCursor?
        if found.count > limit { next = .init(owner: owner, query: query, upper: upper, before: values.last!.1) }
        else if !exhausted { next = .init(owner: owner, query: query, upper: upper, before: boundary) }
        else { next = nil }
        return .init(values: values.map(\.0), next: next)
    }
    public func export(accountID: UUID?, to url: URL) async throws -> Int {
        guard url.isFileURL else { throw TelemostFailure.invalidConfiguration }
        let db = try db(), owner = try owner(accountID)
        let upper = Int64(try db.query("SELECT COALESCE(max(sequence),0) FROM \(db.prefix)telemost_versions").first?.first ?? "0") ?? 0
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".telemost-export-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TelemostFailure.storage }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary); defer { try? handle.close() }
        var boundary: Int64 = 0, count = 0
        while true {
            try Task.checkCancellation()
            let rows = try db.query("SELECT sequence,token,kind,ciphertext FROM \(db.prefix)telemost_versions WHERE owner=$1 AND kind IN('local','conference') AND sequence>$2::bigint AND sequence<=$3::bigint ORDER BY sequence LIMIT 100", [owner, String(boundary), String(upper)])
            if rows.isEmpty { break }
            for row in rows {
                let data: Data
                if row[2] == "local" { let value: TelemostLocalMeeting = try db.decode(row[3], token: "version:" + row[1] + ":" + owner + ":" + row[0]); data = try db.encoded(value) }
                else { let value: TelemostConference = try db.decode(row[3], token: "version:" + row[1] + ":" + owner + ":" + row[0]); data = try db.encoded(value) }
                let object = try JSONSerialization.jsonObject(with: data)
                let envelope: [String: Any] = ["schema": 1, "service": "telemost", "sequence": row[0], "kind": row[2], "value": object]
                try handle.write(contentsOf: JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) + Data([0x0a]))
                boundary = Int64(row[0])!; count += 1
            }
        }
        try handle.synchronize(); try handle.close()
        // Rename atomically on the selected directory's filesystem; the user's Save panel chose the target.
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
        return count
    }
}

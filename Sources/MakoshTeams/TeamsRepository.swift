import Foundation
import CryptoKit
import MakoshCore

public struct TeamsMessagePosition: Codable, Sendable {
    let epoch: Int64
    let offset: Int64
    let firstSequence: Int64
}

public struct TeamsRetainedCursor: Codable, Sendable {
    public let scope: TeamsScope
    public let sequence: Int64
    public let watermark: Int64
    public let query: String?
    public var position: TeamsMessagePosition? = nil
}
public struct TeamsRetainedPage: Sendable {
    public let values: [TeamsMessage]
    public let versionSequences: [Int64]
    public let next: TeamsRetainedCursor?
    public let conflictingMessageIDs: Set<String>
}
public struct TeamsRetainedVersion: Codable, Sendable {
    public let sequence: Int64
    public let observation: MessageArchiveObservation
    public let message: TeamsMessage
}
public struct TeamsCheckpoint: Codable, Equatable, Sendable {
    public let collection: TeamsCollection
    public let next: TeamsContinuation?
    public let complete: Bool
    public let baselineEstablished: Bool
    public let continuationFailure: TeamsFailure?
    public var presentationEpoch: Int64? = nil
    public var presentationOffset: Int64? = nil
}
public struct TeamsIngestResult: Sendable {
    public let inserted: Int
    public let conflictingMessageIDs: Set<String>
}
public struct TeamsArchiveJob: Codable, Sendable {
    public let id: UUID
    public let sequence: Int64
    public let observation: MessageArchiveObservation
}
public enum TeamsLeaseKind: String, Codable, Sendable { case refresh, sync, dispatch }
public struct TeamsLease: Equatable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let operationID: UUID
    public let kind: TeamsLeaseKind
}

public extension TeamsScope {
    var archiveConversationID: String { Data(SHA256.hash(data: storageKey)).teamsBase64URL }
    func archiveIdentity(messageID: String) -> MessageArchiveIdentity {
        MessageArchiveIdentity(service: "teams", accountID: accountID.uuidString, conversationID: archiveConversationID, messageID: messageID)
    }
}

public actor TeamsRepository {
    let keyProvider: @Sendable (UUID, Bool) throws -> Data
    var database: TeamsPostgres?
    private var leases: [UUID: (TeamsLease, TeamsPGConnection)] = [:]
    var outgoingLeases: [UUID: TeamsLease] = [:]
    public init(keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open) { self.keyProvider = keyProvider }
    public func open(configuration: ContactWorkspaceConfiguration) throws {
        if let database {
            guard database.configuration.schema == configuration.schema,
                  database.configuration.archiveSchema == configuration.archiveSchema,
                  database.configuration.connectionString == configuration.connectionString else { throw TeamsFailure.invalidConfiguration }
            return
        }
        let db = try TeamsPostgres(configuration: configuration)
        try db.open(keyProvider: keyProvider); database = db
    }
    func db() throws -> TeamsPostgres { guard let database else { throw TeamsFailure.storage }; return database }
    public func accounts() throws -> [TeamsAccount] {
        let db = try db()
        return try db.query("SELECT token,ciphertext FROM \(db.prefix)teams_accounts ORDER BY token").map { try db.decode($0[1], token: "account:" + $0[0]) }
    }
    func account(_ id: UUID, lock: Bool = false) throws -> TeamsAccount {
        let db = try db(), token = try db.token(["account", id.uuidString])
        guard let row = try db.query("SELECT ciphertext FROM \(db.prefix)teams_accounts WHERE token=$1" + (lock ? " FOR UPDATE" : ""), [token]).first else { throw TeamsFailure.invalidResource }
        let account: TeamsAccount = try db.decode(row[0], token: "account:" + token)
        guard account.id == id else { throw TeamsFailure.storage }; return account
    }
    public func saveAccount(_ account: TeamsAccount) throws {
        try TeamsOAuthConfiguration(clientID: account.clientID, authority: account.authority).validate()
        guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, account.name.utf8.count <= 512 else { throw TeamsFailure.invalidResource }
        let db = try db()
        try db.transaction {
            let token = try db.token(["account", account.id.uuidString])
            let rows = try db.query("SELECT ciphertext FROM \(db.prefix)teams_accounts WHERE token=$1 FOR UPDATE", [token])
            if let row = rows.first {
                let old: TeamsAccount = try db.decode(row[0], token: "account:" + token)
                guard old.clientID == account.clientID, old.authority == account.authority,
                      old.verifiedPrincipal == nil || old.verifiedPrincipal == account.verifiedPrincipal else { throw TeamsFailure.principalChanged }
            }
            _ = try db.query("INSERT INTO \(db.prefix)teams_accounts VALUES($1,$2) ON CONFLICT(token) DO UPDATE SET ciphertext=excluded.ciphertext", [token, try db.seal(account, token: "account:" + token)])
        }
    }
    public func bindPrincipal(accountID: UUID, principal: TeamsPrincipal) throws {
        try bindPrincipalUnchecked(accountID: accountID, principal: principal)
    }
    func bindPrincipal(accountID: UUID, principal: TeamsPrincipal, permit: TeamsAuthorizationPermit) throws {
        try permit.perform { try bindPrincipalUnchecked(accountID: accountID, principal: principal) }
    }
    private func bindPrincipalUnchecked(accountID: UUID, principal: TeamsPrincipal) throws {
        let old = try account(accountID)
        guard old.verifiedPrincipal == nil || old.verifiedPrincipal == principal else { throw TeamsFailure.principalChanged }
        try saveAccount(TeamsAccount(id: old.id, name: old.name, clientID: old.clientID, authority: old.authority, verifiedPrincipal: principal, readOnly: old.readOnly))
    }
    func validate(_ scope: TeamsScope) throws -> TeamsAccount {
        let account = try account(scope.accountID)
        guard let principal = account.verifiedPrincipal, Data(principal.tenantID.utf8) == Data(scope.tenantID.utf8) else { throw TeamsFailure.principalChanged }
        return account
    }
    func collectionToken(_ collection: TeamsCollection) throws -> String {
        try db().token(["collection", collection.context.accountID.uuidString, collection.context.principal.tenantID, collection.context.principal.userID] + collection.kind.components)
    }
    public func checkpoint(collection: TeamsCollection) throws -> TeamsCheckpoint? {
        guard try account(collection.context.accountID).verifiedPrincipal == collection.context.principal else { throw TeamsFailure.principalChanged }
        let db = try db(), token = try collectionToken(collection)
        guard let row = try db.query("SELECT ciphertext FROM \(db.prefix)teams_checkpoints WHERE token=$1", [token]).first else { return nil }
        let value: TeamsCheckpoint = try db.decode(row[0], token: "checkpoint:" + token)
        guard value.collection == collection else { throw TeamsFailure.storage }; return value
    }
    public func commit(page: TeamsPage<TeamsMessage>, collection: TeamsCollection, baseline: Bool, restartOrder: Bool = false) throws -> TeamsIngestResult {
        try db().transaction { try ingestWithinTransaction(page: page, collection: collection, baseline: baseline, restartOrder: restartOrder) }
    }
    func ingestWithinTransaction(page: TeamsPage<TeamsMessage>, collection: TeamsCollection, baseline: Bool, source: MessageArchiveSource? = nil, recordCheckpoint: Bool = true, restartOrder: Bool = false, outgoingFiles: [UUID] = []) throws -> TeamsIngestResult {
        guard page.values.count <= 1000, try account(collection.context.accountID).verifiedPrincipal == collection.context.principal else { throw TeamsFailure.invalidResource }
        let resource: TeamsResource
        switch collection.kind { case let .messages(value), let .replies(value): resource = value; default: throw TeamsFailure.invalidResource }
        let path = try TeamsGraphURL.path(collection.kind.components)
        let db = try db()
            _ = try db.query("SELECT pg_advisory_xact_lock(hashtext('makosh-teams-page'),hashtext($1))", [try collectionToken(collection)])
            let previousCheckpoint = recordCheckpoint ? try checkpoint(collection: collection) : nil
            let reuse = !restartOrder && previousCheckpoint?.complete == false && previousCheckpoint?.presentationEpoch != nil
            let epoch: Int64
            if reuse { epoch = previousCheckpoint!.presentationEpoch! }
            else {
                guard let raw = try db.query("SELECT nextval(pg_get_serial_sequence($1,'sequence'))", [db.prefix + "teams_versions"]).first?.first, let value = Int64(raw) else { throw TeamsFailure.storage }; epoch = value
            }
            let offset = reuse ? previousCheckpoint?.presentationOffset ?? 0 : 0
            guard offset >= 0, offset <= Int64.max - Int64(page.values.count) else { throw TeamsFailure.storage }
            var inserted = 0; var conflicts = Set<String>()
            for (index, message) in page.values.enumerated() {
                guard message.scope.accountID == collection.context.accountID, Data(message.scope.tenantID.utf8) == Data(collection.context.principal.tenantID.utf8),
                      message.scope.resource == resource, !message.id.isEmpty, message.id.utf8.count <= 1024,
                      [message.createdAt, message.modifiedAt, message.deletedAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw TeamsFailure.invalidResource }
                let scope = try db.token(message.scope.storageKey)
                let token = try db.token(["message", scope, message.id])
                let payload = try db.encoded(message), digest = try db.token(payload)
                if try !db.query("SELECT 1 FROM \(db.prefix)teams_versions WHERE message=$1 AND digest=$2", [token, digest]).isEmpty { continue }
                let prior = try db.query("SELECT ciphertext,conflict FROM \(db.prefix)teams_current WHERE token=$1 FOR UPDATE", [token])
                var visible = true; var conflict = false
                if let row = prior.first {
                    let old: TeamsMessage = try db.decode(row[0], token: "current:" + token)
                    let lhs = Self.sourceDate(message), rhs = Self.sourceDate(old)
                    visible = lhs > rhs
                    conflict = row[1] == "t" || lhs == rhs
                    if conflict { conflicts.insert(message.id) }
                }
                let observation = try Self.observation(message, context: collection.context, baseline: baseline, payload: payload, source: source)
                guard let seq = try db.query("SELECT nextval(pg_get_serial_sequence($1,'sequence'))", [db.prefix + "teams_versions"]).first?.first, let sequence = Int64(seq) else { throw TeamsFailure.storage }
                let version = TeamsRetainedVersion(sequence: sequence, observation: observation, message: message)
                _ = try db.query("INSERT INTO \(db.prefix)teams_versions VALUES($1::bigint,$2::uuid,$3,$4,$5,$6::boolean,$7)",
                    [seq, observation.id.uuidString, scope, token, digest, visible ? "true" : "false", try db.seal(version, token: "version:" + seq)])
                if prior.isEmpty {
                    _ = try db.query("INSERT INTO \(db.prefix)teams_message_order VALUES($1,$2,$3::bigint,$4::bigint,$5::bigint)", [token, scope, String(epoch), String(offset + Int64(index)), seq])
                }
                if visible {
                    _ = try db.query("INSERT INTO \(db.prefix)teams_current VALUES($1,$2,$3::bigint,$4::boolean,$5) ON CONFLICT(token) DO UPDATE SET sequence=excluded.sequence,conflict=excluded.conflict,ciphertext=excluded.ciphertext",
                        [token, scope, seq, conflict ? "true" : "false", try db.seal(message, token: "current:" + token)])
                } else if conflict { _ = try db.query("UPDATE \(db.prefix)teams_current SET conflict=true WHERE token=$1", [token]) }
                let job = TeamsArchiveJob(id: observation.id, sequence: sequence, observation: observation)
                _ = try db.query("INSERT INTO \(db.prefix)teams_archive_jobs(id,sequence,ciphertext) VALUES($1::uuid,$2::bigint,$3)",
                    [job.id.uuidString, seq, try db.seal(job, token: "job:" + job.id.uuidString)])
                try reserveIncomingFiles(version, outgoingFiles: outgoingFiles)
                try admitNotification(version, firstSeen: prior.isEmpty, baseline: baseline)
                inserted += 1
            }
            if recordCheckpoint {
            let token = try collectionToken(collection)
            let prior = try checkpoint(collection: collection)
            let validNext = page.next.map { $0.owner == collection && TeamsGraphURL.accepts($0.url, path: path) } ?? true
            let failure = page.continuationFailure ?? (validNext ? nil : TeamsFailure.invalidContinuation)
            let next = failure == nil ? page.next : nil
            let complete = next == nil && failure == nil
            let checkpoint = TeamsCheckpoint(collection: collection, next: next, complete: complete,
                baselineEstablished: prior?.baselineEstablished == true || complete, continuationFailure: failure, presentationEpoch: epoch, presentationOffset: offset + Int64(page.values.count))
            _ = try db.query("INSERT INTO \(db.prefix)teams_checkpoints VALUES($1,$2) ON CONFLICT(token) DO UPDATE SET ciphertext=excluded.ciphertext", [token, try db.seal(checkpoint, token: "checkpoint:" + token)])
            }
            return TeamsIngestResult(inserted: inserted, conflictingMessageIDs: conflicts)
    }
    private static func sourceDate(_ message: TeamsMessage) -> Date { [message.createdAt, message.modifiedAt, message.deletedAt].compactMap { $0 }.max() ?? .distantPast }
    private static func observation(_ message: TeamsMessage, context: TeamsAccountContext, baseline: Bool, payload: Data, source: MessageArchiveSource?) throws -> MessageArchiveObservation {
        let observedAt = Date()
        let event: MessageArchiveEvent = message.deletedAt == nil ? .message(MessageArchiveContent(date: message.createdAt ?? observedAt,
            editedAt: message.modifiedAt, text: message.body, author: message.author?.displayName ?? "", authorID: message.author?.userID,
            isOutgoing: source == .outgoing || message.author?.userID == context.principal.userID,
            attachments: message.attachments.map { MessageArchiveAttachment(id: $0.id, kind: $0.contentType ?? "file", name: $0.name ?? "", size: nil) })) : .deleted
        return MessageArchiveObservation(identity: message.scope.archiveIdentity(messageID: message.id), observedAt: observedAt,
            source: source ?? (baseline ? .history : .update), event: event, sourcePayload: payload)
    }
    public func messages(scope: TeamsScope, before: TeamsRetainedCursor? = nil, limit: Int = 50) throws -> TeamsRetainedPage {
        _ = try validate(scope); try validateCursor(before, scope: scope, query: nil, limit: limit)
        let db = try db(), token = try db.token(scope.storageKey)
        let watermark = try before?.watermark ?? maxSequence(scope: token)
        let position = before?.position
        if before != nil, position == nil { throw TeamsFailure.invalidContinuation }
        let epoch = "COALESCE(o.epoch,v.sequence)", offset = "COALESCE(o.position,0)", first = "COALESCE(o.first_sequence,v.sequence)"
        let rows = try db.query("SELECT v.sequence,v.ciphertext,\(epoch),\(offset),\(first) FROM (SELECT DISTINCT ON(message) sequence,message,ciphertext FROM \(db.prefix)teams_versions WHERE scope=$1 AND visible=true AND sequence<=$2::bigint ORDER BY message,sequence DESC) v LEFT JOIN \(db.prefix)teams_message_order o ON o.message=v.message WHERE (\(epoch)<$3::bigint OR (\(epoch)=$3::bigint AND (\(offset)>$4::bigint OR (\(offset)=$4::bigint AND \(first)<$5::bigint)))) ORDER BY \(epoch) DESC,\(offset) ASC,\(first) DESC LIMIT $6::int", [token, String(watermark), String(position?.epoch ?? Int64.max), String(position?.offset ?? -1), String(position?.firstSequence ?? Int64.max), String(limit + 1)])
        let versions: [TeamsRetainedVersion] = try rows.map { try db.decode($0[1], token: "version:" + $0[0]) }
        let kept = Array(versions.prefix(limit))
        let positions: [TeamsMessagePosition] = try rows.prefix(limit).map { row in
            guard let epoch = Int64(row[2]), let offset = Int64(row[3]), let first = Int64(row[4]) else { throw TeamsFailure.storage }
            return TeamsMessagePosition(epoch: epoch, offset: offset, firstSequence: first)
        }
        let conflicts = try db.query("SELECT token,ciphertext FROM \(db.prefix)teams_current WHERE scope=$1 AND conflict=true", [token]).map { row -> String in
            let message: TeamsMessage = try db.decode(row[1], token: "current:" + row[0]); return message.id
        }
        return TeamsRetainedPage(values: kept.map(\.message), versionSequences: kept.map(\.sequence), next: versions.count > limit ? kept.last.map { TeamsRetainedCursor(scope: scope, sequence: $0.sequence, watermark: watermark, query: nil, position: positions.last) } : nil, conflictingMessageIDs: Set(conflicts))
    }
    public func versions(scope: TeamsScope, messageID: String, before: Int64? = nil, limit: Int = 50) throws -> [TeamsRetainedVersion] {
        _ = try validate(scope); guard (1...100).contains(limit), !messageID.isEmpty else { throw TeamsFailure.invalidResource }
        let db = try db(), token = try db.token(["message", db.token(scope.storageKey), messageID])
        return try db.query("SELECT sequence,ciphertext FROM \(db.prefix)teams_versions WHERE message=$1 AND sequence<$2::bigint ORDER BY sequence DESC LIMIT $3::int", [token, String(before ?? Int64.max), String(limit)]).map { try db.decode($0[1], token: "version:" + $0[0]) }
    }
    public func search(scope: TeamsScope, query: String, before: TeamsRetainedCursor? = nil, limit: Int = 50) async throws -> TeamsRetainedPage {
        _ = try validate(scope); try validateCursor(before, scope: scope, query: query, limit: limit)
        guard !query.isEmpty, query.utf8.count <= 1024 else { throw TeamsFailure.invalidResource }
        let db = try db(), token = try db.token(scope.storageKey)
        let watermark = try before?.watermark ?? maxSequence(scope: token)
        var cursor = before?.sequence ?? Int64.max
        var found: [TeamsRetainedVersion] = []
        while found.count <= limit {
            try Task.checkCancellation()
            let rows = try db.query("SELECT sequence,ciphertext FROM \(db.prefix)teams_versions WHERE scope=$1 AND sequence<=$2::bigint AND sequence<$3::bigint ORDER BY sequence DESC LIMIT 100", [token, String(watermark), String(cursor)])
            if rows.isEmpty { break }
            for row in rows {
                let version: TeamsRetainedVersion = try db.decode(row[1], token: "version:" + row[0])
                cursor = version.sequence
                if version.message.body.localizedCaseInsensitiveContains(query) || version.message.attachments.contains(where: { ($0.name ?? "").localizedCaseInsensitiveContains(query) }) { found.append(version) }
                if found.count > limit { break }
            }
            if rows.count < 100 || found.count > limit { break }
            await Task.yield()
        }
        let kept = Array(found.prefix(limit))
        return TeamsRetainedPage(values: kept.map(\.message), versionSequences: kept.map(\.sequence), next: found.count > limit ? kept.last.map { TeamsRetainedCursor(scope: scope, sequence: $0.sequence, watermark: watermark, query: query) } : nil, conflictingMessageIDs: [])
    }
    private func validateCursor(_ cursor: TeamsRetainedCursor?, scope: TeamsScope, query: String?, limit: Int) throws {
        guard (1...100).contains(limit) else { throw TeamsFailure.invalidResource }
        if let cursor { guard cursor.scope == scope, cursor.query.map({ Data($0.utf8) }) == query.map({ Data($0.utf8) }), cursor.sequence > 0, cursor.watermark >= cursor.sequence else { throw TeamsFailure.invalidContinuation } }
    }
    private func maxSequence(scope: String) throws -> Int64 { Int64(try db().query("SELECT COALESCE(max(sequence),0) FROM \(db().prefix)teams_versions WHERE scope=$1", [scope]).first?.first ?? "0") ?? 0 }
    public func pendingProjection(limit: Int = 50) throws -> [TeamsArchiveJob] {
        guard (1...100).contains(limit) else { throw TeamsFailure.invalidResource }
        let db = try db()
        return try db.query("SELECT id,ciphertext FROM \(db.prefix)teams_archive_jobs WHERE acked=false ORDER BY sequence LIMIT $1::int", [String(limit)]).map {
            guard let id = UUID(uuidString: $0[0]) else { throw TeamsFailure.storage }
            let value: TeamsArchiveJob = try db.decode($0[1], token: "job:" + id.uuidString)
            guard value.id == id else { throw TeamsFailure.storage }; return value
        }
    }
    public func acknowledgeProjection(id: UUID) throws {
        let db = try db(); try db.transaction { _ = try db.query("UPDATE \(db.prefix)teams_archive_jobs SET acked=true WHERE id=$1::uuid", [id.uuidString]) }
    }
    public func acquireLease(kind: TeamsLeaseKind, accountID: UUID, operationID: UUID) throws -> TeamsLease {
        _ = try account(accountID)
        let db = try db(), connection = TeamsPGConnection(dsn: db.configuration.connectionString)
        try connection.open()
        do {
            let token = try db.token(["lease", db.configuration.schema, kind.rawValue, accountID.uuidString])
            guard try connection.query("SELECT pg_try_advisory_lock(hashtextextended($1,0))", [token]).first?.first == "t" else { throw TeamsFailure.operationBusy }
            let lease = TeamsLease(id: UUID(), accountID: accountID, operationID: operationID, kind: kind)
            leases[lease.id] = (lease, connection); return lease
        } catch { connection.close(); throw error }
    }
    public func releaseLease(_ lease: TeamsLease) throws {
        guard let current = leases[lease.id], current.0 == lease else { throw TeamsFailure.operationBusy }
        current.1.close(); leases[lease.id] = nil
    }
    public func close() {
        for value in leases.values { value.1.close() }; leases.removeAll(); outgoingLeases.removeAll()
        database?.close(); database = nil
    }
}

extension TeamsRepository {
    private func directory<T: Decodable>(accountID: UUID, category: String, type: T.Type) throws -> [T] {
        _ = try account(accountID)
        let db = try db(), owner = try db.token(["directory-account", accountID.uuidString])
        return try db.query("SELECT token,ciphertext FROM \(db.prefix)teams_directory WHERE account=$1 AND category=$2 ORDER BY token", [owner, category]).map { try db.decode($0[1], token: "directory:" + $0[0]) }
    }
    public func conversations(accountID: UUID) throws -> [TeamsConversation] { try directory(accountID: accountID, category: "chats", type: TeamsConversation.self) }
    public func teams(accountID: UUID) throws -> [TeamsTeam] { try directory(accountID: accountID, category: "teams", type: TeamsTeam.self) }
    public func channels(accountID: UUID, teamID: String? = nil) throws -> [TeamsChannel] {
        let values = try directory(accountID: accountID, category: "channels", type: TeamsChannel.self)
        return values.filter { value in teamID.map { Data($0.utf8) == Data(value.teamID.utf8) } ?? true }
    }
    func saveConversations(_ values: [TeamsConversation], collection: TeamsCollection, next: TeamsContinuation?, failure: TeamsFailure?) throws {
        guard collection.kind == .chats, values.allSatisfy({ $0.scope.accountID == collection.context.accountID && Data($0.scope.tenantID.utf8) == Data(collection.context.principal.tenantID.utf8) }) else { throw TeamsFailure.invalidResource }
        try saveDirectory(values, ids: values.map { $0.scope.archiveConversationID }, category: "chats", collection: collection, next: next, failure: failure)
    }
    func saveTeams(_ values: [TeamsTeam], collection: TeamsCollection, next: TeamsContinuation?, failure: TeamsFailure?) throws {
        guard collection.kind == .joinedTeams else { throw TeamsFailure.invalidResource }
        try saveDirectory(values, ids: values.map(\.id), category: "teams", collection: collection, next: next, failure: failure)
    }
    func saveChannels(_ values: [TeamsChannel], collection: TeamsCollection, next: TeamsContinuation?, failure: TeamsFailure?) throws {
        guard case let .channels(team) = collection.kind, values.allSatisfy({ Data($0.teamID.utf8) == Data(team.utf8) }) else { throw TeamsFailure.invalidResource }
        try saveDirectory(values, ids: values.map { Data(teamsIdentityKey([$0.teamID, $0.id])).teamsBase64URL }, category: "channels", collection: collection, next: next, failure: failure)
    }
    private func saveDirectory<T: Encodable>(_ values: [T], ids: [String], category: String, collection: TeamsCollection, next: TeamsContinuation?, failure: TeamsFailure?) throws {
        guard values.count == ids.count, try account(collection.context.accountID).verifiedPrincipal == collection.context.principal else { throw TeamsFailure.principalChanged }
        let db = try db(), path = try TeamsGraphURL.path(collection.kind.components)
        try db.transaction {
            let owner = try db.token(["directory-account", collection.context.accountID.uuidString])
            for (value, id) in zip(values, ids) {
                guard !id.isEmpty, id.utf8.count <= 4096 else { throw TeamsFailure.invalidResource }
                let token = try db.token([owner, category, id])
                _ = try db.query("INSERT INTO \(db.prefix)teams_directory VALUES($1,$2,$3,$4) ON CONFLICT(token) DO UPDATE SET ciphertext=excluded.ciphertext", [token, owner, category, try db.seal(value, token: "directory:" + token)])
            }
            let valid = next.map { $0.owner == collection && TeamsGraphURL.accepts($0.url, path: path) } ?? true
            let error = failure ?? (valid ? nil : .invalidContinuation)
            let cursor = error == nil ? next : nil
            let checkpoint = TeamsCheckpoint(collection: collection, next: cursor, complete: cursor == nil && error == nil, baselineEstablished: false, continuationFailure: error)
            let token = try collectionToken(collection)
            _ = try db.query("INSERT INTO \(db.prefix)teams_checkpoints VALUES($1,$2) ON CONFLICT(token) DO UPDATE SET ciphertext=excluded.ciphertext", [token, try db.seal(checkpoint, token: "checkpoint:" + token)])
        }
    }
}

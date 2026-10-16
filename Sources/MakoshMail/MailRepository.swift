import Foundation
import CryptoKit
import CPostgres
import MakoshCore

public struct MailSnapshot: Codable, Sendable {
    public var accounts: [MailAccount] = []
    public var folders: [MailFolder] = []
    public var letters: [MailLetter] = []
    public var drafts: [MailDraft] = []
    public var submissions: [MailSubmission] = []
    public var notifications: MailNotificationState?
    public var automation: MailAutomationState?
    public init() {}
}
/// All SQL/encryption lives on this executor. State contains text/metadata, never file bytes.
public actor MailRepository {
    private let configuration: ContactWorkspaceConfiguration
    private let keyProvider: @Sendable (UUID,Bool) throws -> Data
    private var database: MailDatabase?
    private var attempts: [String: MailOperationLease] = [:]
    private func lease(_ kind: String, _ id: UUID) throws -> MailOperationLease { try MailOperationLease(configuration: configuration, kind: kind, id: id) }
    func endSubmissionAttempt(_ id: UUID) { attempts.removeValue(forKey: "smtp|" + id.uuidString) }
    public init(configuration: ContactWorkspaceConfiguration,
                keyProvider: @escaping @Sendable (UUID,Bool) throws -> Data = MessageArchiveKeychain.open) {
        self.configuration=configuration;self.keyProvider=keyProvider
    }
    private func db() throws -> MailDatabase {
        if let database { return database }
        let database=try MailDatabase(configuration:configuration,keyProvider:keyProvider)
        self.database=database;return database
    }
    public func snapshot() throws -> MailSnapshot { try db().snapshot() }
    public func letter(_ id: String) throws -> MailLetter? { try db().letter(id) }
    public func versions(_ id: String, beforeSequence: Int64?, limit: Int = 20) throws -> [MailLetterVersion] { try db().versions(id, beforeSequence: beforeSequence, limit: limit) }
    public func cachedPage(folder: MailFolder?, beforeSequence: Int64?, limit: Int = 50) throws -> [MailLetter] { try db().headers(folder: folder, beforeSequence: beforeSequence, limit: limit) }
    public func saveAccount(_ account: MailAccount) throws {
        try account.validate()
        try db().mutate { state in
            guard state.accounts.first(where: { $0.id == account.id }).map({ $0.sameSource(as: account) }) != false else { throw MailFailure.invalidInput }
            state.accounts.removeAll { $0.id==account.id };state.accounts.append(account)
        }
    }
    public func validateAccountSource(_ account: MailAccount) throws {
        try account.validate()
        guard try snapshot().accounts.first(where: { $0.id == account.id }).map({ $0.sameSource(as: account) }) != false else { throw MailFailure.invalidInput }
    }
    public func saveFolders(_ folders: [MailFolder],accountID: String) throws {
        guard folders.allSatisfy({ $0.accountID==accountID }) else { throw MailFailure.invalidInput }
        try db().mutate { state in
            let previous = state.folders
            state.folders.removeAll { $0.accountID == accountID }
            state.folders.append(contentsOf: folders.map { folder in
                var result = folder
                result.uidValidity = folder.uidValidity ?? previous.first(where: { $0.id == folder.id })?.uidValidity
                return result
            })
        }
    }
    public func saveLetters(_ letters: [MailLetter]) throws {
        try db().saveLetters(letters)
    }
    public func savePage(_ letters: [MailLetter], folder: MailFolder, uidValidity: UInt32, notifyIncoming: Bool = false, synchronizedThroughUID: UInt32? = nil) throws {
        guard uidValidity > 0, letters.allSatisfy({ $0.key.accountID == folder.accountID && $0.key.folder == folder.path && $0.key.uidValidity == uidValidity }) else { throw MailFailure.invalidInput }
        try db().mutate { state in
            for letter in letters { try self.db().upsert(letter) }
            var selected = folder; selected.uidValidity = uidValidity
            if let index = state.folders.firstIndex(where: { $0.id == folder.id }) { state.folders[index] = selected }
            else { state.folders.append(selected) }
            if notifyIncoming {
                var automation = state.automation ?? .init()
                automation.observe(letters, folder: folder, validity: uidValidity, synchronizedThroughUID: synchronizedThroughUID); state.automation = automation
                var notifications = state.notifications ?? .init()
                notifications.observe(letters,folder:folder,uidValidity:uidValidity,synchronizedThroughUID:synchronizedThroughUID); state.notifications = notifications
            }
        }
    }

    public func updateNotificationPreferences(_ preferences: MailNotificationPreferences) throws {
        try db().mutate { state in
            var notifications = state.notifications ?? .init()
            notifications.preferences = preferences; state.notifications = notifications
        }
    }
    public func setNotificationRule(scope:MailNotificationScope,rule:MailNotificationRule?,showWhileActive:Bool?=nil) throws {
        guard showWhileActive == nil || scope == .global else { throw MailFailure.invalidInput }
        try db().mutate { state in
            var notifications = state.notifications ?? .init()
            if scope == .global { notifications.preferences.global = rule ?? .init() }
            else { notifications.preferences.overrides[scope.id] = rule }
            if let showWhileActive { notifications.preferences.showWhileActive = showWhileActive }
            state.notifications = notifications
        }
    }
    public func takeNotificationEvents(accountID:String) throws -> [MailNotificationEvent] {
        try takeNotificationBatch(accountIDs: [accountID]).events
    }
    public func takeNotificationBatch(accountIDs: Set<String>) throws -> MailNotificationBatch {
        var result: MailNotificationBatch?
        try db().mutate { state in
            var notifications = state.notifications ?? .init()
            var events: [MailNotificationEvent] = [], eventHeaders: [MailLetter] = []
            for event in notifications.pending where accountIDs.contains(event.key.accountID) {
                guard notifications.preferences.effective(for:event).enabled,
                      state.folders.contains(where: { $0.accountID == event.key.accountID && $0.path == event.key.folder && $0.uidValidity == event.key.uidValidity }),
                      let letter = try self.db().letter(event.id,preview:true), !letter.seen, letter.removedFromSource != true else { continue }
                events.append(event); eventHeaders.append(letter)
                if notifications.routes?[event.id] == nil {
                    var routes = notifications.routes ?? [:]
                    routes[event.id] = .init(event: event, rule: notifications.preferences.effective(for: event))
                    if routes.count > 100, let oldest = routes.min(by: { $0.value.created < $1.value.created })?.key { routes.removeValue(forKey: oldest) }
                    notifications.routes = routes
                }
            }
            for route in notifications.routes?.values.filter({ !$0.consumed }) ?? [] {
                if let letter = try self.db().letter(route.event.id, preview: true), !eventHeaders.contains(where: { $0.id == letter.id }) { eventHeaders.append(letter) }
            }
            notifications.pending.removeAll { accountIDs.contains($0.key.accountID) }; state.notifications = notifications
            var snapshot = state
            snapshot.letters = try self.db().headers(folder: nil, beforeSequence: nil, limit: 1000)
            let loaded = Set(snapshot.letters.map(\.id))
            snapshot.letters.append(contentsOf: eventHeaders.filter { !loaded.contains($0.id) })
            result = MailNotificationBatch(events: events, snapshot: snapshot)
        }
        guard let result else { throw MailFailure.storage }; return result
    }
    public func claimNotificationAction(_ id: String) throws -> Bool {
        var claimed = false
        try db().mutate { snapshot in
            guard let route = snapshot.notifications?.routes?[id], !route.consumed,
                  snapshot.accounts.contains(where: { $0.id == route.event.key.accountID }),
                  snapshot.folders.contains(where: { $0.accountID == route.event.key.accountID && $0.path == route.event.key.folder && $0.uidValidity == route.event.key.uidValidity }),
                  let letter = try self.db().letter(id), letter.key == route.event.key, !letter.seen, letter.removedFromSource != true,
                  snapshot.notifications?.preferences.effective(for: letter) == route.rule, route.rule.enabled else { return }
            snapshot.notifications?.routes?[id]?.consumed = true; claimed = true
        }
        return claimed
    }

    public func saveDraft(_ draft: MailDraft) throws {
        try draft.validateForSaving()
        try db().mutate { state in
            if let scheduled = state.automation?.scheduled?.first(where: { $0.draft.id == draft.id && $0.state != .cancelled && $0.state != .completed }) {
                guard scheduled.state == .admitted, scheduled.draft == draft else { throw MailFailure.unknownSubmission }
            }
            var value = draft
            if let existing = state.drafts.first(where: { $0.id == draft.id }) { value.remoteSave = existing.remoteSave }
            state.drafts.removeAll { $0.id==draft.id };state.drafts.append(value)
        }
    }
    public func setSignature(accountID: String, text: String) throws {
        guard !accountID.isEmpty, text.utf8.count <= 65536, !text.contains("\0") else { throw MailFailure.invalidInput }
        try db().mutate { state in var value = state.automation ?? .init(); value.signatures[accountID] = text; state.automation = value }
    }
    public func saveTemplate(_ template: MailReplyTemplate) throws {
        guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, template.name.count <= 200, template.body.utf8.count <= 65536 else { throw MailFailure.invalidInput }
        try db().mutate { state in
            var value = state.automation ?? .init()
            value.templates.removeAll { $0.id == template.id }; guard value.templates.count < 1000 else { throw MailFailure.invalidInput }
            value.templates.append(template); state.automation = value
        }
    }
    public func deleteTemplate(_ id: UUID) throws { try db().mutate { $0.automation?.templates.removeAll { $0.id == id } } }
    public func saveIncomingRule(_ rule: MailIncomingRule) throws {
        guard !rule.accountID.isEmpty, !rule.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.value.count <= 998,
              rule.action != .label || (rule.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && (rule.label?.count ?? 0) <= 100) else { throw MailFailure.invalidInput }
        try db().mutate { state in
            var value = state.automation ?? .init(); value.rules.removeAll { $0.id == rule.id }
            guard value.rules.count < 1000 else { throw MailFailure.invalidInput }
            value.rules.append(rule); state.automation = value
        }
    }
    public func deleteIncomingRule(_ id: UUID) throws { try db().mutate { $0.automation?.rules.removeAll { $0.id == id } } }
    public func claimRuleOperation(_ id: UUID) throws -> MailRuleOperation? {
        var result: MailRuleOperation?
        var owned: MailOperationLease?
        try db().mutate { state in
            guard let i = state.automation?.ruleOperations.firstIndex(where: { $0.id == id && $0.state == .pending }),
                  let value = state.automation?.ruleOperations[i],
                  state.folders.contains(where: { $0.accountID == value.key.accountID && $0.path == value.key.folder && $0.uidValidity == value.key.uidValidity }),
                  let letter = try self.db().letter(value.key.id), letter.removedFromSource != true else { return }
            owned = try self.lease("rule", id)
            state.automation?.ruleOperations[i].state = .admitted; result = state.automation?.ruleOperations[i]
        }
        if let owned { attempts["rule|" + id.uuidString] = owned }
        return result
    }
    public func finishRuleOperation(_ id: UUID, state: MailRuleOperation.State) throws {
        guard attempts["rule|" + id.uuidString] != nil else { throw MailFailure.invalidInput }
        defer { attempts.removeValue(forKey: "rule|" + id.uuidString) }
        try db().mutate { snapshot in
            guard let i = snapshot.automation?.ruleOperations.firstIndex(where: { $0.id == id && $0.state == .admitted }) else { throw MailFailure.invalidInput }
            snapshot.automation?.ruleOperations[i].state = state
        }
    }
    public func failRulePreparation(_ id: UUID, failure: MailFailure) throws {
        try db().mutate { snapshot in
            guard let i = snapshot.automation?.ruleOperations.firstIndex(where: { $0.id == id && $0.state == .pending }) else { return }
            snapshot.automation?.ruleOperations[i].state = .preparationFailed
            snapshot.automation?.ruleOperations[i].failure = failure.localizedDescription
        }
    }
    public func retryRulePreparation(_ id: UUID, cancel: Bool = false) throws {
        try db().mutate { snapshot in
            guard let i = snapshot.automation?.ruleOperations.firstIndex(where: { $0.id == id && $0.state == .preparationFailed }) else { throw MailFailure.invalidInput }
            snapshot.automation?.ruleOperations[i].state = cancel ? .cancelled : .pending
            snapshot.automation?.ruleOperations[i].failure = nil
        }
    }
    public func resolveRuleOperation(_ id: UUID) throws {
        let owner = try lease("rule", id); defer { withExtendedLifetime(owner) {} }
        try db().mutate { snapshot in
            guard let i = snapshot.automation?.ruleOperations.firstIndex(where: { $0.id == id && ($0.state == .admitted || $0.state == .unknown) }) else { throw MailFailure.invalidInput }
            snapshot.automation?.ruleOperations[i].state = .cancelled
        }
    }
    public func schedule(_ draft: MailDraft, at date: Date, now: Date = Date()) throws -> MailScheduledSend {
        try draft.validate()
        guard date > now, date.timeIntervalSince(now) <= 366 * 24 * 3600 else { throw MailFailure.invalidInput }
        let scheduled = MailScheduledSend(draft: draft, sendAt: date)
        try db().mutate { snapshot in
            guard snapshot.accounts.contains(where: { $0.id == draft.accountID }),
                  !snapshot.submissions.contains(where: { $0.draftID == draft.id && $0.state != .rejected && $0.state != .userConfirmedNotSent }) else { throw MailFailure.unknownSubmission }
            var value = snapshot.automation ?? .init(); var items = value.scheduled ?? []
            guard !items.contains(where: { $0.draft.id == draft.id && $0.state != .cancelled }), items.count < 10000 else { throw MailFailure.unknownSubmission }
            snapshot.drafts.removeAll { $0.id == draft.id }; snapshot.drafts.append(draft)
            items.append(scheduled); value.scheduled = items; snapshot.automation = value
        }
        return scheduled
    }
    public func claimScheduled(accountID: String, now: Date = Date()) throws -> MailScheduledSend? {
        var result: MailScheduledSend?
        var owned: MailOperationLease?
        try db().mutate { snapshot in
            guard let candidate = snapshot.automation?.scheduled?.filter({ $0.draft.accountID == accountID && $0.state == .pending && $0.sendAt <= now }).min(by: { $0.sendAt < $1.sendAt }),
                  let i = snapshot.automation?.scheduled?.firstIndex(where: { $0.id == candidate.id }) else { return }
            guard !snapshot.submissions.contains(where: { $0.draftID == candidate.draft.id && $0.state != .rejected && $0.state != .userConfirmedNotSent }) else {
                snapshot.automation?.scheduled?[i].state = .unknown; return
            }
            owned = try self.lease("schedule", candidate.id)
            snapshot.automation?.scheduled?[i].state = .admitted; result = snapshot.automation?.scheduled?[i]
        }
        if let owned, let result { attempts["schedule|" + result.id.uuidString] = owned }
        return result
    }
    public func finishSchedule(_ id: UUID, state: MailScheduledSend.State) throws {
        guard attempts["schedule|" + id.uuidString] != nil else { throw MailFailure.invalidInput }
        defer { attempts.removeValue(forKey: "schedule|" + id.uuidString) }
        try db().mutate { snapshot in
            guard let i = snapshot.automation?.scheduled?.firstIndex(where: { $0.id == id && $0.state == .admitted }) else { throw MailFailure.invalidInput }
            snapshot.automation?.scheduled?[i].state = state
        }
    }
    public func cancelSchedule(_ id: UUID) throws {
        try db().mutate { snapshot in
            guard let i = snapshot.automation?.scheduled?.firstIndex(where: { $0.id == id && $0.state == .pending }) else { throw MailFailure.invalidInput }
            snapshot.automation?.scheduled?[i].state = .cancelled
        }
    }
    public func resolveSchedule(_ id: UUID, wasSent: Bool) throws {
        let owner = try lease("schedule", id)
        var submissions: [MailOperationLease] = []
        defer { withExtendedLifetime(owner) {}; withExtendedLifetime(submissions) {} }
        try db().mutate { snapshot in
            guard let i = snapshot.automation?.scheduled?.firstIndex(where: { $0.id == id && ($0.state == .admitted || $0.state == .unknown) }), let item = snapshot.automation?.scheduled?[i] else { throw MailFailure.invalidInput }
            for submission in snapshot.submissions where submission.draftID == item.draft.id && (submission.state == .unknown || submission.state == .submitting) {
                submissions.append(try self.lease("smtp", submission.id))
            }
            snapshot.automation?.scheduled?[i].state = wasSent ? .completed : .cancelled
            for j in snapshot.submissions.indices where snapshot.submissions[j].draftID == item.draft.id && (snapshot.submissions[j].state == .unknown || snapshot.submissions[j].state == .submitting) {
                snapshot.submissions[j].state = wasSent ? .userConfirmedSent : .userConfirmedNotSent
            }
            if wasSent { snapshot.drafts.removeAll { $0.id == item.draft.id } }
        }
    }
    public func admitDraftAppend(_ id: UUID, digest: String) throws -> MailDraftRemoteSave? {
        var admitted: MailDraftRemoteSave?
        try db().mutate { state in
            guard let i = state.drafts.firstIndex(where: { $0.id == id }) else { throw MailFailure.storage }
            if let previous = state.drafts[i].remoteSave {
                guard !previous.unresolved else { throw MailFailure.unknownDraftSave }
                if previous.digest == digest && (previous.state == .saved || previous.state == .userConfirmedSaved) { return }
            }
            let receipt = MailDraftRemoteSave(digest: digest, state: .appending)
            state.drafts[i].remoteSave = receipt; admitted = receipt
        }
        return admitted
    }
    public func updateDraftRemoteSave(_ id: UUID, expected: MailDraftRemoteSave, state: MailDraftRemoteSave.State) throws {
        try db().mutate { snapshot in
            guard let i = snapshot.drafts.firstIndex(where: { $0.id == id }), var save = snapshot.drafts[i].remoteSave else { throw MailFailure.storage }
            guard save.unresolved, save == expected else { throw MailFailure.invalidInput }
            save.state = state; snapshot.drafts[i].remoteSave = save
        }
    }
    public func deleteDraft(_ id: UUID) throws { try db().mutate { $0.drafts.removeAll { $0.id==id } } }
    public func admit(_ submission: MailSubmission) throws {
        let owner = try lease("smtp", submission.id)
        try db().mutate { state in
            guard state.automation?.scheduled?.contains(where: {
                $0.draft.id == submission.draftID && ($0.state == .pending || $0.state == .unknown || ($0.state == .admitted && self.attempts["schedule|" + $0.id.uuidString] == nil))
            }) != true else { throw MailFailure.unknownSubmission }
            guard !state.submissions.contains(where: { $0.draftID==submission.draftID && $0.state != .rejected && $0.state != .userConfirmedNotSent }) else { throw MailFailure.unknownSubmission }
            state.submissions.append(submission)
        }
        attempts["smtp|" + submission.id.uuidString] = owner
    }
    public func resolveUnknown(_ id: UUID, wasSent: Bool) throws {
        let owner = try lease("smtp", id); defer { withExtendedLifetime(owner) {} }
        try db().mutate { state in
            guard let i = state.submissions.firstIndex(where: { $0.id == id }),
                  state.submissions[i].state == .unknown || state.submissions[i].state == .submitting else { throw MailFailure.invalidInput }
            state.submissions[i].state = wasSent ? .userConfirmedSent : .userConfirmedNotSent
            if wasSent { let draftID = state.submissions[i].draftID; state.drafts.removeAll { $0.id == draftID } }
        }
    }
    public func updateSubmission(_ submission: MailSubmission) throws {
        defer { if submission.state != .submitting { endSubmissionAttempt(submission.id) } }
        try db().mutate { state in
            guard let i=state.submissions.firstIndex(where: { $0.id==submission.id }) else { throw MailFailure.storage }
            let previous = state.submissions[i]
            guard previous.accountID == submission.accountID, previous.draftID == submission.draftID,
                  (previous.state == .submitting && self.attempts["smtp|" + submission.id.uuidString] != nil) || (previous.state == .accepted && submission.state == .accepted) else { throw MailFailure.invalidInput }
            state.submissions[i]=submission
            state.submissions[i].sentCopySaved = previous.sentCopySaved || submission.sentCopySaved
        }
    }
}

private final class MailDatabase {
    private var connection: OpaquePointer?
    private let table: String
    private let letterTable: String
    private let versionTable: String
    private var key: SymmetricKey!
    private var vault: UUID!
    private var blocked=false
    init(configuration: ContactWorkspaceConfiguration,keyProvider: (UUID,Bool) throws -> Data) throws {
        let schema=configuration.schema
        guard schema.utf8.count<=63,let first=schema.utf8.first,(97...122).contains(first),
              schema.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0==95 }),!configuration.connectionString.utf8.contains(0) else { throw MailFailure.storage }
        table="\"\(schema)\".mail_state"
        letterTable="\"\(schema)\".mail_letters"
        versionTable="\"\(schema)\".mail_letter_versions"
        connection=configuration.connectionString.withCString { dsn in
            "dbname".withCString { k in "connect_timeout".withCString { t in "5".withCString { v in
                let keys:[UnsafePointer<CChar>?]=[k,t,nil],values:[UnsafePointer<CChar>?]=[dsn,v,nil]
                return keys.withUnsafeBufferPointer { ks in values.withUnsafeBufferPointer { vs in PQconnectdbParams(ks.baseAddress,vs.baseAddress,1) } }
            } } }
        }
        guard let connection,PQstatus(connection)==CONNECTION_OK else { if let connection { PQfinish(connection) };self.connection=nil;throw MailFailure.storage }
        PQsetNoticeProcessor(connection,{ _,_ in },nil)
        do {
            _=try query("SET client_encoding TO 'UTF8'");_=try query("SET statement_timeout TO '15s'");_=try query("SET lock_timeout TO '5s'")
            _=try query("BEGIN")
            _=try query("SELECT pg_advisory_xact_lock(hashtext('makosh-mail'),hashtext($1))",[schema])
            _=try query("CREATE SCHEMA IF NOT EXISTS \"\(schema)\"")
            _=try query("CREATE TABLE IF NOT EXISTS \(table) (id SMALLINT PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, vault UUID NOT NULL, ciphertext TEXT NOT NULL)")
            _ = try query("CREATE TABLE IF NOT EXISTS \(letterTable) (sequence BIGSERIAL UNIQUE, token TEXT PRIMARY KEY, account_token TEXT NOT NULL, folder_token TEXT NOT NULL, ciphertext TEXT NOT NULL, preview TEXT)")
            _ = try query("ALTER TABLE \(letterTable) ADD COLUMN IF NOT EXISTS preview TEXT")
            _ = try query("ALTER TABLE \(letterTable) ADD COLUMN IF NOT EXISTS uid_validity BIGINT")
            _ = try query("ALTER TABLE \(letterTable) ADD COLUMN IF NOT EXISTS removed BOOLEAN NOT NULL DEFAULT FALSE")
            _ = try query("CREATE INDEX IF NOT EXISTS mail_folder_page ON \(letterTable) (folder_token,uid_validity,sequence DESC) WHERE NOT removed")
            _ = try query("CREATE TABLE IF NOT EXISTS \(versionTable) (sequence BIGSERIAL PRIMARY KEY, token TEXT NOT NULL, digest TEXT NOT NULL, ciphertext TEXT NOT NULL, UNIQUE(token,digest))")
            _ = try query("CREATE OR REPLACE FUNCTION \"\(schema)\".mail_no_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'append only'; END $$")
            _ = try query("DROP TRIGGER IF EXISTS mail_no_rewrite ON \(versionTable)")
            _ = try query("CREATE TRIGGER mail_no_rewrite BEFORE UPDATE OR DELETE OR TRUNCATE ON \(versionTable) FOR EACH STATEMENT EXECUTE FUNCTION \"\(schema)\".mail_no_rewrite()")
            let rows=try query("SELECT version,vault,ciphertext FROM \(table) WHERE id=1 FOR UPDATE")
            let fresh=rows.isEmpty
            if fresh { vault=UUID() } else {
                guard ["1", "2"].contains(rows[0][0]),let id=UUID(uuidString:rows[0][1]) else { throw MailFailure.storage };vault=id
            }
            let raw=try keyProvider(vault,fresh);guard raw.count==32 else { throw MailFailure.keychain }
            key=HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:raw),salt:Data(vault.uuidString.utf8),info:Data("makosh-mail-state-v1".utf8),outputByteCount:32)
            if fresh { _=try query("INSERT INTO \(table) VALUES (1,2,$1::uuid,$2)",[vault.uuidString,try seal(MailSnapshot())]) }
            else {
                var previous = try decode(rows[0][2])
                if rows[0][0] == "1" {
                    for letter in previous.letters { try upsert(letter) }
                    previous.letters = []
                    _ = try query("UPDATE \(table) SET version=2,ciphertext=$1 WHERE id=1", [try seal(previous)])
                }
            }
            for row in try query("SELECT token,ciphertext FROM \(letterTable) WHERE preview IS NULL OR uid_validity IS NULL") { try upsert(decodeLetter(row[1], token: row[0])) }
            _=try query("COMMIT")
        } catch { _=try? query("ROLLBACK");PQfinish(connection);self.connection=nil;throw MailFailure.storage }
    }
    deinit { if let connection { PQfinish(connection) } }
    func snapshot() throws -> MailSnapshot {
        var state = try load(); state.letters = try headers(folder: nil, beforeSequence: nil, limit: 1000); return state
    }
    func headers(folder: MailFolder?, beforeSequence: Int64?, limit: Int) throws -> [MailLetter] {
        var filters: [String] = [], parameters: [String] = []
        if let folder {
            let token = SHA256.hash(data: Data((folder.accountID + "|" + folder.path).utf8)).map { String(format: "%02x", $0) }.joined()
            parameters.append(token); filters.append("folder_token=$1")
            filters.append("NOT removed")
            if let validity = folder.uidValidity { parameters.append(String(validity)); filters.append("uid_validity=$\(parameters.count)::bigint") }
        }
        if let beforeSequence {
            guard beforeSequence > 0 else { throw MailFailure.invalidInput }
            parameters.append(String(beforeSequence)); filters.append("sequence<$\(parameters.count)::bigint")
        }
        let predicate = filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND ")
        let rows = try query("SELECT sequence,token,preview FROM \(letterTable)" + predicate + " ORDER BY sequence DESC LIMIT \(min(1000, max(1, limit)))", parameters)
        return try rows.map { row in
            var value = try decodeLetter(row[2], token: row[1], preview: true)
            value.cacheSequence = Int64(row[0]); return value
        }
    }
    func letter(_ id: String, preview:Bool=false) throws -> MailLetter? {
        let column = preview ? "preview" : "ciphertext"
        let rows = try query("SELECT \(column) FROM \(letterTable) WHERE token=$1", [id])
        return try rows.first.map { try decodeLetter($0[0], token: id, preview:preview) }
    }
    func versions(_ id: String, beforeSequence: Int64?, limit: Int) throws -> [MailLetterVersion] {
        guard beforeSequence == nil || beforeSequence! > 0 else { throw MailFailure.invalidInput }
        var parameters = [id], condition = "token=$1"
        if let beforeSequence { parameters.append(String(beforeSequence)); condition += " AND sequence<$2::bigint" }
        return try query("SELECT sequence,ciphertext FROM \(versionTable) WHERE " + condition + " ORDER BY sequence DESC LIMIT \(min(20,max(1,limit)))", parameters).map { row in
            guard let sequence = Int64(row[0]) else { throw MailFailure.storage }
            return MailLetterVersion(id: sequence, letter: try decodeLetter(row[1], token: id))
        }
    }
    func saveLetters(_ letters: [MailLetter]) throws {
        try mutate { _ in for letter in letters { try upsert(letter) } }
    }
    func upsert(_ letter: MailLetter) throws {
        var value = letter
        if let existing = try self.letter(letter.id), value.text == nil || value.isBodyPreview == true {
            value.text = existing.text; value.html = existing.html; value.attachments = existing.attachments
            value.cc = value.cc ?? existing.cc; value.bcc = value.bcc ?? existing.bcc
        }
        value.isBodyPreview = nil; value.cacheSequence = nil
        let raw = try JSONEncoder().encode(value)
        guard let combined = try AES.GCM.seal(raw, using: key, authenticating: Data((vault.uuidString + "|letter|" + value.id).utf8)).combined else { throw MailFailure.storage }
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        _ = try query("INSERT INTO \(versionTable) (token,digest,ciphertext) VALUES ($1,$2,$3) ON CONFLICT(token,digest) DO NOTHING", [value.id, digest, combined.base64EncodedString()])
        let accountToken = SHA256.hash(data: Data(value.key.accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        let folderToken = SHA256.hash(data: Data((value.key.accountID + "|" + value.key.folder).utf8)).map { String(format: "%02x", $0) }.joined()
        var preview = value
        if let text = value.text { preview.text = String(text.prefix(160)); preview.isBodyPreview = true }
        preview.html = nil
        let previewData = try JSONEncoder().encode(preview)
        guard let previewBytes = try AES.GCM.seal(previewData, using: key, authenticating: Data((vault.uuidString + "|letter-preview|" + value.id).utf8)).combined else { throw MailFailure.storage }
        _ = try query("INSERT INTO \(letterTable) (token,account_token,folder_token,ciphertext,preview,uid_validity,removed) VALUES ($1,$2,$3,$4,$5,$6::bigint,$7::boolean) ON CONFLICT(token) DO UPDATE SET ciphertext=EXCLUDED.ciphertext,preview=EXCLUDED.preview,uid_validity=EXCLUDED.uid_validity,removed=EXCLUDED.removed", [value.id, accountToken, folderToken, combined.base64EncodedString(), previewBytes.base64EncodedString(), String(value.key.uidValidity), value.removedFromSource == true ? "true" : "false"])
    }
    private func decodeLetter(_ value: String, token: String, preview: Bool = false) throws -> MailLetter {
        guard let data = Data(base64Encoded: value) else { throw MailFailure.storage }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data((vault.uuidString + (preview ? "|letter-preview|" : "|letter|") + token).utf8))
        let result = try JSONDecoder().decode(MailLetter.self, from: clear)
        guard result.id == token else { throw MailFailure.storage }; return result
    }
    private func load() throws -> MailSnapshot {
        let rows=try query("SELECT ciphertext FROM \(table) WHERE id=1")
        guard rows.count==1 else { throw MailFailure.storage };return try decode(rows[0][0])
    }
    func mutate(_ action: (inout MailSnapshot) throws -> Void) throws {
        guard !blocked else { throw MailFailure.storage }
        _=try query("BEGIN")
        do {
            let rows=try query("SELECT ciphertext FROM \(table) WHERE id=1 FOR UPDATE")
            guard rows.count==1 else { throw MailFailure.storage }
            var state=try decode(rows[0][0]);try action(&state)
            _=try query("UPDATE \(table) SET ciphertext=$1 WHERE id=1",[try seal(state)])
        } catch { _=try? query("ROLLBACK");throw error }
        do { _=try query("COMMIT") }
        catch { blocked=true;throw MailFailure.storage }
    }
    private func seal(_ state: MailSnapshot) throws -> String {
        let data=try JSONEncoder().encode(state)
        guard let sealed=try AES.GCM.seal(data,using:key,authenticating:Data(vault.uuidString.utf8)).combined else { throw MailFailure.storage }
        return sealed.base64EncodedString()
    }
    private func decode(_ value: String) throws -> MailSnapshot {
        guard let data=Data(base64Encoded:value) else { throw MailFailure.storage }
        do { return try JSONDecoder().decode(MailSnapshot.self,from:AES.GCM.open(AES.GCM.SealedBox(combined:data),using:key,authenticating:Data(vault.uuidString.utf8))) }
        catch { throw MailFailure.storage }
    }
    private func query(_ sql: String,_ parameters: [String]=[]) throws -> [[String]] {
        guard let connection,!parameters.contains(where: { $0.utf8.contains(0) }) else { throw MailFailure.storage }
        let pointers=parameters.map { strdup($0) };defer { pointers.forEach { free($0) } }
        let const=pointers.map { UnsafePointer<CChar>($0) }
        let result=const.withUnsafeBufferPointer { PQexecParams(connection,sql,Int32(parameters.count),nil,$0.baseAddress,nil,nil,0) }
        guard let result else { throw MailFailure.storage };defer { PQclear(result) }
        guard PQresultStatus(result)==PGRES_TUPLES_OK || PQresultStatus(result)==PGRES_COMMAND_OK else { throw MailFailure.storage }
        return (0..<PQntuples(result)).map { row in (0..<PQnfields(result)).map { String(cString:PQgetvalue(result,row,$0)) } }
    }
}


import Foundation

public struct TeamsNotificationRule: Codable, Equatable, Sendable {
    public var show = true, preview = true, sound = true, foreground = true
    public init() {}
    func restricting(_ other: Self) -> Self {
        var value = self
        value.show = show && other.show; value.preview = preview && other.preview
        value.sound = sound && other.sound; value.foreground = foreground && other.foreground
        return value
    }
}
public enum TeamsNotificationScope: Codable, Hashable, Sendable { case global, account(UUID), conversation(TeamsScope) }
public struct TeamsNotificationEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let thread: String
    public let scope: TeamsScope
    public let messageID: String
    public let sequence: Int64
    public let title: String
    public let body: String
    public let timestamp: Int64
    public init(id: String, thread: String, scope: TeamsScope, messageID: String, sequence: Int64, title: String, body: String, timestamp: Int64) {
        self.id = id; self.thread = thread; self.scope = scope; self.messageID = messageID; self.sequence = sequence
        self.title = title; self.body = body; self.timestamp = timestamp
    }
}
public protocol TeamsNotificationServing: Sendable {
    func savedNotificationRule(scope: TeamsNotificationScope) async throws -> TeamsNotificationRule
    func setNotificationRule(_ rule: TeamsNotificationRule, scope: TeamsNotificationScope) async throws
    func notificationRule(conversation: TeamsScope) async throws -> TeamsNotificationRule
    func claimNotifications(accountID: UUID) async throws -> [TeamsNotificationEvent]
    func notificationIsCurrent(_ event: TeamsNotificationEvent) async throws -> Bool
    func activateNotification(token: String) async throws -> TeamsNotificationEvent?
    func markLocallyRead(scope: TeamsScope) async throws
}
public enum TeamsTextProjection {
    public static func plain(_ body: String, contentType: String) -> String {
        guard contentType.lowercased() == "html" else { return body }
        var value = body.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/li)>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (encoded, decoded) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] { value = value.replacingOccurrences(of: encoded, with: decoded) }
        return value
    }
}

extension TeamsRepository {
    private func notificationScopeToken(_ scope: TeamsNotificationScope) throws -> String {
        switch scope {
        case .global: return try db().token(["notification-rule", "global"])
        case let .account(id): _ = try account(id); return try db().token(["notification-rule", "account", id.uuidString])
        case let .conversation(scope): _ = try validate(scope); return try db().token(teamsIdentityKey(["notification-rule", "conversation"]) + scope.storageKey)
        }
    }
    public func savedNotificationRule(scope: TeamsNotificationScope) throws -> TeamsNotificationRule {
        let db = try db(), token = try notificationScopeToken(scope)
        guard let row = try db.query("SELECT ciphertext FROM \(db.prefix)teams_preferences WHERE token=$1", [token]).first else { return .init() }
        return try db.decode(row[0], token: "preference:" + token)
    }
    public func setNotificationRule(_ rule: TeamsNotificationRule, scope: TeamsNotificationScope) throws {
        let db = try db(), token = try notificationScopeToken(scope)
        _ = try db.query("INSERT INTO \(db.prefix)teams_preferences VALUES($1,$2) ON CONFLICT(token) DO UPDATE SET ciphertext=excluded.ciphertext", [token, try db.seal(rule, token: "preference:" + token)])
    }
    public func notificationRule(conversation scope: TeamsScope) throws -> TeamsNotificationRule {
        _ = try validate(scope)
        var rule = try savedNotificationRule(scope: .global).restricting(savedNotificationRule(scope: .account(scope.accountID)))
            .restricting(savedNotificationRule(scope: .conversation(scope.policyScope)))
        if scope.policyScope != scope { rule = try rule.restricting(savedNotificationRule(scope: .conversation(scope))) }
        return rule
    }
    private func localMessageToken(scope: TeamsScope, messageID: String) throws -> String {
        try db().token(scope.storageKey + teamsIdentityKey(["local-unread", messageID]))
    }
    func admitNotification(_ version: TeamsRetainedVersion, firstSeen: Bool, baseline: Bool) throws {
        let message = version.message, scope = message.scope, db = try db()
        guard firstSeen, !baseline, message.deletedAt == nil, version.observation.source != .outgoing,
              message.metadata["messageType"] == nil || message.metadata["messageType"] == "message",
              message.author?.userID != (try account(scope.accountID).verifiedPrincipal?.userID) else { return }
        let local = try localMessageToken(scope: scope, messageID: message.id)
        _ = try db.query("INSERT INTO \(db.prefix)teams_local_unread VALUES($1,$2,$3,$4::bigint,false,$5) ON CONFLICT(token) DO NOTHING",
            [local, try db.token(scope.policyScope.storageKey), try db.token(scope.storageKey), String(version.sequence), try db.seal(scope, token: "unread:" + local)])
        let now = Int64(Date().timeIntervalSince1970)
        guard let created = message.createdAt, created.timeIntervalSince1970 >= Double(now - 120), created.timeIntervalSince1970 <= Double(now + 60) else { return }
        let token = try db.token(["notification", version.observation.id.uuidString])
        let title = try conversations(accountID: scope.accountID).first { $0.scope == scope.policyScope }?.displayName
            ?? channels(accountID: scope.accountID).first { scope.policyScope.resource == .channel(teamID: $0.teamID, channelID: $0.id) }?.displayName ?? "Microsoft Teams"
        let event = TeamsNotificationEvent(id: token, thread: try db.token(scope.policyScope.storageKey + Data("notification-thread".utf8)), scope: scope,
            messageID: message.id, sequence: version.sequence, title: String(title.prefix(256)),
            body: String(TeamsTextProjection.plain(message.body, contentType: message.contentType).prefix(512)), timestamp: Int64(created.timeIntervalSince1970))
        let rule = try notificationRule(conversation: scope)
        _ = try db.query("INSERT INTO \(db.prefix)teams_notifications VALUES($1,$2,$3::bigint,$4,$5)",
            [token, try db.token(["notification-account", scope.accountID.uuidString]), String(version.sequence), rule.show ? "queued" : "suppressed", try db.seal(event, token: "notification:" + token)])
    }
    public func markLocallyRead(scope: TeamsScope) throws {
        _ = try validate(scope); let db = try db()
        let exact: Bool = { if case .thread = scope.resource { return true }; return false }()
        _ = try db.query("UPDATE \(db.prefix)teams_local_unread SET read=true WHERE " + (exact ? "exactscope" : "scope") + "=$1", [try db.token(scope.storageKey)])
    }
    public func localUnreadCount(scope: TeamsScope) throws -> Int {
        _ = try validate(scope); let db = try db()
        let exact: Bool = { if case .thread = scope.resource { return true }; return false }()
        guard let raw = try db.query("SELECT count(*) FROM \(db.prefix)teams_local_unread WHERE read=false AND " + (exact ? "exactscope" : "scope") + "=$1", [try db.token(scope.storageKey)]).first?.first, let count = Int(raw) else { throw TeamsFailure.storage }; return count
    }
    public func notificationIsCurrent(_ event: TeamsNotificationEvent) throws -> Bool {
        _ = try validate(event.scope)
        guard try notificationRule(conversation: event.scope).show else { return false }
        let db = try db(), scope = try db.token(event.scope.storageKey)
        let token = try db.token(["message", scope, event.messageID])
        guard let row = try db.query("SELECT sequence,ciphertext FROM \(db.prefix)teams_current WHERE token=$1", [token]).first,
              row[0] == String(event.sequence) else { return false }
        let message: TeamsMessage = try db.decode(row[1], token: "current:" + token)
        guard message.deletedAt == nil else { return false }
        return try !db.query("SELECT 1 FROM \(db.prefix)teams_local_unread WHERE token=$1 AND read=false", [localMessageToken(scope: event.scope, messageID: event.messageID)]).isEmpty
    }
    public func claimNotifications(accountID: UUID) throws -> [TeamsNotificationEvent] {
        _ = try account(accountID); let db = try db()
        return try db.transaction {
            let rows = try db.query("SELECT token,ciphertext FROM \(db.prefix)teams_notifications WHERE account=$1 AND state='queued' ORDER BY sequence LIMIT 100 FOR UPDATE SKIP LOCKED", [try db.token(["notification-account", accountID.uuidString])])
            var events: [TeamsNotificationEvent] = []
            let now = Int64(Date().timeIntervalSince1970)
            for row in rows {
                let event: TeamsNotificationEvent = try db.decode(row[1], token: "notification:" + row[0])
                if event.timestamp >= now - 120, event.timestamp <= now + 60, try notificationIsCurrent(event) { events.append(event) }
                _ = try db.query("UPDATE \(db.prefix)teams_notifications SET state='consumed' WHERE token=$1", [row[0]])
            }
            return events
        }
    }
    public func activateNotification(token: String) throws -> TeamsNotificationEvent? {
        guard Self.validNotificationToken(token) else { throw TeamsFailure.invalidResource }
        let db = try db()
        return try db.transaction {
            guard let row = try db.query("SELECT ciphertext FROM \(db.prefix)teams_notifications WHERE token=$1 AND state='consumed' FOR UPDATE", [token]).first else { return nil }
            let event: TeamsNotificationEvent = try db.decode(row[0], token: "notification:" + token)
            guard try notificationIsCurrent(event) else { return nil }
            _ = try db.query("UPDATE \(db.prefix)teams_notifications SET state='activated' WHERE token=$1", [token]); return event
        }
    }
    public static func validNotificationToken(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}

extension TeamsWorker: TeamsNotificationServing {
    public func savedNotificationRule(scope: TeamsNotificationScope) async throws -> TeamsNotificationRule { try check(); return try await repository.savedNotificationRule(scope: scope) }
    public func setNotificationRule(_ rule: TeamsNotificationRule, scope: TeamsNotificationScope) async throws { try check(); try await repository.setNotificationRule(rule, scope: scope) }
    public func notificationRule(conversation: TeamsScope) async throws -> TeamsNotificationRule { try check(); return try await repository.notificationRule(conversation: conversation) }
    public func claimNotifications(accountID: UUID) async throws -> [TeamsNotificationEvent] {
        try check(); guard let generation = generations[accountID], sessions[accountID] != nil else { return [] }
        let events = try await repository.claimNotifications(accountID: accountID); try check(accountID: accountID, generation: generation); return events
    }
    public func notificationIsCurrent(_ event: TeamsNotificationEvent) async throws -> Bool {
        try check(); guard let generation = generations[event.scope.accountID], sessions[event.scope.accountID] != nil else { return false }
        let current = try await repository.notificationIsCurrent(event); try check(accountID: event.scope.accountID, generation: generation); return current
    }
    public func activateNotification(token: String) async throws -> TeamsNotificationEvent? { try check(); return try await repository.activateNotification(token: token) }
    public func markLocallyRead(scope: TeamsScope) async throws { try check(); try await repository.markLocallyRead(scope: scope) }
    public func localUnreadCount(scope: TeamsScope) async throws -> Int { try check(); return try await repository.localUnreadCount(scope: scope) }
}

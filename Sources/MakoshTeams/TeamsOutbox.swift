import Foundation
import MakoshCore

public struct TeamsDraft: Codable, Sendable {
    public let text: String
    public let fileIDs: [UUID]
    public init(text: String, fileIDs: [UUID] = []) { self.text = text; self.fileIDs = fileIDs }
}
public struct TeamsOutgoingReceipt: Codable, Sendable {
    public let providerMessageID: String?
    public let acceptedAt: Date
    public let userResolved: Bool
}
public struct TeamsOutgoing: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case prepared, dispatching, accepted, notSent, unknown }
    public let id: UUID
    public let scope: TeamsScope
    public let content: TeamsDraft
    public let createdAt: Date
    public let sequence: Int64
    public var state: State
    public var attemptID: UUID?
    var ownerID: UUID?
    public var receipt: TeamsOutgoingReceipt?
    public var failure: TeamsFailure?
    public var fileSubmission: TeamsFileSubmissionState?
}
public struct TeamsOutgoingCursor: Codable, Sendable {
    public let accountID: UUID
    public let sequence: Int64
}
public struct TeamsOutgoingPage: Sendable {
    public let values: [TeamsOutgoing]
    public let next: TeamsOutgoingCursor?
}
public enum TeamsAttemptOutcome: Sendable { case accepted(TeamsMessage), notSent(TeamsFailure), unknown }

extension TeamsRepository {
    public func prepareOutgoing(scope: TeamsScope, content: TeamsDraft) throws -> TeamsOutgoing {
        try db().transaction { try prepare(scope: scope, content: content, filePlan: nil) }
    }
    func prepare(scope: TeamsScope, content: TeamsDraft, filePlan: TeamsFileAccessPlan?) throws -> TeamsOutgoing {
        _ = try validate(scope)
        _ = try TeamsGraphURL.path(TeamsCollection.Kind.messages(scope.resource).components)
        guard (!content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filePlan != nil),
              content.text.utf8.count <= 1024 * 1024, content.fileIDs.isEmpty || filePlan?.fileIDs == content.fileIDs else { throw TeamsFailure.invalidResource }
        let db = try db()
        return try {
            guard try !account(scope.accountID, lock: true).readOnly else { throw TeamsFailure.forbidden }
            guard let raw = try db.query("SELECT nextval(pg_get_serial_sequence($1,'sequence'))", [db.prefix + "teams_outbox"]).first?.first,
                  let sequence = Int64(raw) else { throw TeamsFailure.storage }
            var value = TeamsOutgoing(id: UUID(), scope: scope, content: content, createdAt: Date(), sequence: sequence, state: .prepared)
            if let filePlan { value.fileSubmission = TeamsFileSubmissionState(plan: filePlan, stages: []) }
            try storeOutgoing(value, insert: true)
            return value
        }()
    }
    private func outgoingToken(_ id: UUID, accountID: UUID) throws -> String { try db().token(["outgoing", accountID.uuidString, id.uuidString]) }
    func outgoingRaw(id: UUID, accountID: UUID, lock: Bool = false) throws -> TeamsOutgoing {
        _ = try account(accountID)
        let db = try db(), token = try outgoingToken(id, accountID: accountID)
        guard let row = try db.query("SELECT sequence,state,ciphertext FROM \(db.prefix)teams_outbox WHERE token=$1 AND account=$2" + (lock ? " FOR UPDATE" : ""), [token, try db.token(["outbox-account", accountID.uuidString])]).first else { throw TeamsFailure.invalidResource }
        let value: TeamsOutgoing = try db.decode(row[2], token: "outgoing:" + token)
        guard value.id == id, value.scope.accountID == accountID, String(value.sequence) == row[0], value.state.rawValue == row[1] else { throw TeamsFailure.storage }
        return value
    }
    func storeOutgoing(_ value: TeamsOutgoing, insert: Bool = false) throws {
        let db = try db(), token = try outgoingToken(value.id, accountID: value.scope.accountID)
        let owner = try db.token(["outbox-account", value.scope.accountID.uuidString])
        let cipher = try db.seal(value, token: "outgoing:" + token)
        if insert {
            _ = try db.query("INSERT INTO \(db.prefix)teams_outbox(sequence,token,account,state,ciphertext) VALUES($1::bigint,$2,$3,$4,$5)", [String(value.sequence), token, owner, value.state.rawValue, cipher])
        } else {
            guard try db.query("UPDATE \(db.prefix)teams_outbox SET state=$3,ciphertext=$4 WHERE token=$1 AND account=$2 RETURNING token", [token, owner, value.state.rawValue, cipher]).count == 1 else { throw TeamsFailure.storage }
        }
    }
    public func outgoing(id: UUID, accountID: UUID) throws -> TeamsOutgoing {
        let value = try outgoingRaw(id: id, accountID: accountID)
        guard value.state == .dispatching, outgoingLeases[id] == nil else { return value }
        let lease: TeamsLease
        do { lease = try acquireLease(kind: .dispatch, accountID: accountID, operationID: UUID()) }
        catch TeamsFailure.operationBusy { return value }
        defer { try? releaseLease(lease) }
        return try db().transaction {
            var current = try outgoingRaw(id: id, accountID: accountID, lock: true)
            if current.state == .dispatching { current.state = .unknown; current.ownerID = nil; try storeOutgoing(current) }
            return current
        }
    }
    public func claimOutgoing(id: UUID, accountID: UUID) throws -> TeamsOutgoing {
        let current = try outgoing(id: id, accountID: accountID)
        guard current.state == .prepared else { throw current.state == .unknown || current.state == .dispatching ? TeamsFailure.uncertainSubmission : .invalidResource }
        let attempt = UUID()
        let lease = try acquireLease(kind: .dispatch, accountID: accountID, operationID: attempt)
        do {
            let claimed = try db().transaction {
                guard try !account(accountID, lock: true).readOnly else { throw TeamsFailure.forbidden }
                var value = try outgoingRaw(id: id, accountID: accountID, lock: true)
                guard value.state == .prepared else { throw TeamsFailure.uncertainSubmission }
                value.state = .dispatching; value.attemptID = attempt; value.ownerID = lease.id
                try storeOutgoing(value); return value
            }
            outgoingLeases[id] = lease; return claimed
        } catch { try? releaseLease(lease); throw error }
    }
    public func settleOutgoing(id: UUID, accountID: UUID, attemptID: UUID, outcome: TeamsAttemptOutcome) throws -> TeamsOutgoing {
        guard let lease = outgoingLeases[id], lease.accountID == accountID, lease.operationID == attemptID else { throw TeamsFailure.operationBusy }
        defer { outgoingLeases[id] = nil; try? releaseLease(lease) }
        let db = try db()
        return try db.transaction {
            var value = try outgoingRaw(id: id, accountID: accountID, lock: true)
            guard value.state == .dispatching, value.attemptID == attemptID, value.ownerID == lease.id else { throw TeamsFailure.operationBusy }
            switch outcome {
            case let .accepted(message):
                guard message.scope == value.scope, !message.id.isEmpty else { throw TeamsFailure.invalidResponse }
                guard let principal = try account(accountID).verifiedPrincipal else { throw TeamsFailure.principalChanged }
                let collection = TeamsCollection(context: TeamsAccountContext(accountID: accountID, principal: principal), kind: .messages(value.scope.resource))
                _ = try ingestWithinTransaction(page: TeamsPage(values: [message], next: nil, continuationFailure: nil), collection: collection, baseline: false, source: .outgoing, recordCheckpoint: false, outgoingFiles: value.content.fileIDs)
                try bindOutgoingPreparations(message: message, fileIDs: value.content.fileIDs)
                value.state = .accepted; value.receipt = TeamsOutgoingReceipt(providerMessageID: message.id, acceptedAt: Date(), userResolved: false)
            case let .notSent(failure): value.state = .notSent; value.failure = failure
            case .unknown: value.state = .unknown
            }
            value.ownerID = nil
            try storeOutgoing(value); return value
        }
    }
    public func resolveOutgoing(id: UUID, accountID: UUID, sent: Bool) throws -> TeamsOutgoing {
        let lease = try acquireLease(kind: .dispatch, accountID: accountID, operationID: UUID())
        defer { try? releaseLease(lease) }
        return try db().transaction {
            var value = try outgoingRaw(id: id, accountID: accountID, lock: true)
            guard value.state == .unknown || value.state == .dispatching else { throw TeamsFailure.invalidResource }
            value.state = sent ? .accepted : .notSent; value.ownerID = nil
            value.receipt = TeamsOutgoingReceipt(providerMessageID: nil, acceptedAt: Date(), userResolved: true)
            try storeOutgoing(value); return value
        }
    }
    public func outgoingPage(accountID: UUID, before: TeamsOutgoingCursor?, limit: Int = 50) throws -> TeamsOutgoingPage {
        _ = try account(accountID)
        guard (1...100).contains(limit), before?.accountID == nil || before?.accountID == accountID else { throw TeamsFailure.invalidContinuation }
        let db = try db(), owner = try db.token(["outbox-account", accountID.uuidString])
        let rows = try db.query("SELECT token,ciphertext FROM \(db.prefix)teams_outbox WHERE account=$1 AND sequence<$2::bigint ORDER BY sequence DESC LIMIT $3::int", [owner, String(before?.sequence ?? Int64.max), String(limit + 1)])
        let decoded: [TeamsOutgoing] = try rows.map { try db.decode($0[1], token: "outgoing:" + $0[0]) }
        let values = try decoded.prefix(limit).map { value in try outgoing(id: value.id, accountID: accountID) }
        return TeamsOutgoingPage(values: values, next: decoded.count > limit ? values.last.map { TeamsOutgoingCursor(accountID: accountID, sequence: $0.sequence) } : nil)
    }
}

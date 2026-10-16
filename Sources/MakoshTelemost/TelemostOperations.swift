import Foundation

public enum TelemostOperationPayload: Codable, Equatable, Sendable {
    case create(TelemostCreateRequest)
    case update(TelemostScope, TelemostMeetingPatch)
    public var scope: TelemostScope? { if case let .update(scope, _) = self { scope } else { nil } }
}
public enum TelemostOperationState: String, Codable, Sendable {
    case prepared, dispatching, accepted, rejected, unknown, resolved
    public var title: String {
        switch self {
        case .prepared: "Подготовлено"; case .dispatching: "Запрос отправлен"; case .accepted: "Подтверждено сервисом"
        case .rejected: "Отклонено сервисом"; case .unknown: "Исход неизвестен"; case .resolved: "Разрешено пользователем"
        }
    }
}
public struct TelemostOperation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let payload: TelemostOperationPayload
    public let attemptID: UUID
    public let createdAt: Date
    public var state: TelemostOperationState
    public var receipt: TelemostConference?
    public var rejectionStatus: Int?
    public init(id: UUID = UUID(), accountID: UUID, payload: TelemostOperationPayload, attemptID: UUID = UUID()) {
        self.id = id; self.accountID = accountID; self.payload = payload; self.attemptID = attemptID
        createdAt = Date(); state = .prepared; receipt = nil; rejectionStatus = nil
    }
}
public enum TelemostOperationOutcome: Sendable { case accepted(TelemostConference), rejected(Int), unknown }
public enum TelemostLeaseKind: String, Sendable { case auth, dispatch, refreshKnown }
public struct TelemostLease: Equatable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let operationID: UUID
    public let kind: TelemostLeaseKind
}

extension TelemostRepository {
    public func prepare(_ operation: TelemostOperation) throws {
        let db = try db(); _ = try account(id: operation.accountID)
        guard operation.state == .prepared, operation.receipt == nil, operation.rejectionStatus == nil,
              operation.payload.scope.map({ $0.accountID == operation.accountID }) ?? true else { throw TelemostFailure.conflict }
        try db.transaction {
            guard try record(TelemostOperation.self, kind: "operation", key: operation.id.uuidString) == nil else { throw TelemostFailure.conflict }
            let pending: [TelemostOperation] = try records(TelemostOperation.self, kind: "operation", owner: owner(operation.accountID), status: "unknown", limit: 1)
            guard pending.isEmpty else { throw TelemostFailure.unknown }
            try put(operation, kind: "operation", key: operation.id.uuidString, owner: owner(operation.accountID), status: operation.state.rawValue)
        }
    }
    public func operation(id: UUID) throws -> TelemostOperation {
        guard let value = try record(TelemostOperation.self, kind: "operation", key: id.uuidString), value.id == id else { throw TelemostFailure.missing }
        return value
    }
    public func operations(accountID: UUID) throws -> [TelemostOperation] {
        _ = try account(id: accountID)
        let values: [TelemostOperation] = try records(TelemostOperation.self, kind: "operation", owner: owner(accountID))
        guard values.allSatisfy({ $0.accountID == accountID }) else { throw TelemostFailure.storage }; return values
    }
    private func ownedDispatch(_ operation: TelemostOperation) throws {
        guard let lease = leases.values.first(where: { $0.0.accountID == operation.accountID && $0.0.operationID == operation.id && $0.0.kind == .dispatch }) else { throw TelemostFailure.busy }
        _ = try lease.1.query("SELECT 1")
    }
    public func begin(operationID: UUID, attemptID: UUID) throws -> TelemostOperation {
        let db = try db(), current = try operation(id: operationID); try ownedDispatch(current)
        return try db.transaction {
            var value = try operation(id: operationID)
            guard value.attemptID == attemptID, value.state == .prepared else { throw TelemostFailure.conflict }
            value.state = .dispatching
            try put(value, kind: "operation", key: value.id.uuidString, owner: owner(value.accountID), status: value.state.rawValue)
            return value
        }
    }
    public func settle(operationID: UUID, attemptID: UUID, outcome: TelemostOperationOutcome) throws {
        let db = try db(), current = try operation(id: operationID); try ownedDispatch(current)
        try db.transaction {
            var value = try operation(id: operationID)
            guard value.attemptID == attemptID, [.dispatching, .unknown].contains(value.state) else { throw TelemostFailure.conflict }
            switch outcome {
            case .accepted(let conference):
                guard conference.scope.accountID == value.accountID,
                      value.payload.scope.map({ $0 == conference.scope }) ?? true else { throw TelemostFailure.conflict }
                try retainInTransaction(conference)
                value.receipt = conference; value.state = .accepted
            case .rejected(let status):
                guard (400..<500).contains(status), status != 408, status != 429 else { throw TelemostFailure.conflict }
                value.rejectionStatus = status; value.state = .rejected
            case .unknown: value.state = .unknown
            }
            try put(value, kind: "operation", key: value.id.uuidString, owner: owner(value.accountID), status: value.state.rawValue)
        }
    }
    public func resolveUnknown(operationID: UUID, receipt: TelemostConference? = nil) throws {
        let db = try db(), current = try operation(id: operationID); try ownedDispatch(current)
        try db.transaction {
            var value = try operation(id: operationID)
            guard value.state == .unknown, value.payload.scope == nil || receipt != nil else { throw TelemostFailure.conflict }
            if let receipt {
                guard receipt.scope.accountID == value.accountID,
                      value.payload.scope.map({ $0 == receipt.scope }) ?? true else { throw TelemostFailure.conflict }
                try retainInTransaction(receipt); value.receipt = receipt
            }
            value.state = .resolved
            try put(value, kind: "operation", key: value.id.uuidString, owner: owner(value.accountID), status: value.state.rawValue)
        }
    }
    public func acquireLease(accountID: UUID, operationID: UUID, kind: TelemostLeaseKind) throws -> TelemostLease {
        let db = try db(); _ = try account(id: accountID)
        let connection = TelemostPGConnection(dsn: db.configuration.connectionString); try connection.open()
        do {
            let key = db.configuration.schema + "/makosh-telemost-account/" + accountID.uuidString
            guard try connection.query("SELECT pg_try_advisory_lock(hashtextextended($1,0))", [key]).first?.first == "t" else { throw TelemostFailure.busy }
            let lease = TelemostLease(id: UUID(), accountID: accountID, operationID: operationID, kind: kind)
            leases[lease.id] = (lease, connection); return lease
        } catch { connection.close(); throw error }
    }
    public func releaseLease(_ lease: TelemostLease) throws {
        guard let current = leases[lease.id], current.0 == lease else { throw TelemostFailure.busy }
        current.1.close(); leases[lease.id] = nil
    }
    func recoverDispatching() throws {
        let db = try db()
        let values: [TelemostOperation] = try records(TelemostOperation.self, kind: "operation", status: "dispatching", limit: 1000)
        for value in values {
            let lease: TelemostLease
            do { lease = try acquireLease(accountID: value.accountID, operationID: value.id, kind: .dispatch) }
            catch TelemostFailure.busy { continue }
            defer { try? releaseLease(lease) }
            try db.transaction {
                var current = try operation(id: value.id)
                if current.state == .dispatching {
                    current.state = .unknown
                    try put(current, kind: "operation", key: current.id.uuidString, owner: owner(current.accountID), status: current.state.rawValue)
                }
            }
        }
    }
}

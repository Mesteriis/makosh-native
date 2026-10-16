import Foundation

/// No token bytes are stored here. Epoch binds rejection to the confirmed grant that used it.
struct TelemostCredentialGate: Codable, Sendable {
    var epoch: UUID?
    var requiresLogin: Bool
}
extension TelemostRepository {
    func credentialGate(accountID: UUID) throws -> TelemostCredentialGate {
        _ = try account(id: accountID)
        return try record(TelemostCredentialGate.self, kind: "auth-gate", key: accountID.uuidString) ?? .init(epoch: nil, requiresLogin: false)
    }
    private func checkCredentialLease(_ lease: TelemostLease, accountID: UUID) throws {
        guard lease.accountID == accountID, let held = leases[lease.id], held.0 == lease else { throw TelemostFailure.busy }
        _ = try held.1.query("SELECT 1")
    }
    func confirmCredential(accountID: UUID, epoch: UUID, lease: TelemostLease) throws {
        guard lease.kind == .auth else { throw TelemostFailure.busy }; try checkCredentialLease(lease, accountID: accountID)
        let db = try db()
        try db.transaction { try put(TelemostCredentialGate(epoch: epoch, requiresLogin: false), kind: "auth-gate", key: accountID.uuidString, owner: owner(accountID)) }
    }
    @discardableResult func rejectCredential(accountID: UUID, epoch: UUID?, lease: TelemostLease) throws -> Bool {
        guard lease.kind == .dispatch || lease.kind == .refreshKnown else { throw TelemostFailure.busy }; try checkCredentialLease(lease, accountID: accountID)
        let db = try db()
        return try db.transaction {
            var gate = try credentialGate(accountID: accountID)
            guard gate.epoch == epoch else { return false }
            gate.requiresLogin = true
            try put(gate, kind: "auth-gate", key: accountID.uuidString, owner: owner(accountID)); return true
        }
    }
}

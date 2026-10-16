import XCTest
@testable import MakoshTelemost

@MainActor
final class TelemostOperationTests: XCTestCase {
    func setup() async throws -> (TelemostTestDatabase, TelemostRepository) {
        let db = try TelemostTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repo = TelemostRepository(keyProvider: telemostTestKey); try await repo.open(configuration: db.configuration)
        addTeardownBlock { await repo.close() }; try await repo.saveAccount(telemostTestAccount)
        return (db, repo)
    }
    func testRestartAndLateSettlement() async throws {
        let (db, repo) = try await setup()
        let operation = TelemostOperation(accountID: telemostTestAccountID, payload: .create(.init(waitingRoom: .admins)))
        try await repo.prepare(operation)
        let lease = try await repo.acquireLease(accountID: operation.accountID, operationID: operation.id, kind: .dispatch)
        _ = try await repo.begin(operationID: operation.id, attemptID: operation.attemptID)
        await repo.close()
        let reopened = TelemostRepository(keyProvider: telemostTestKey); try await reopened.open(configuration: db.configuration)
        addTeardownBlock { await reopened.close() }
        let restored = try await reopened.operation(id: operation.id); XCTAssertEqual(restored.state, .unknown)
        do { _ = try await reopened.begin(operationID: operation.id, attemptID: operation.attemptID); XCTFail("replay admitted") } catch {}
        let resolutionLease = try await reopened.acquireLease(accountID: operation.accountID, operationID: operation.id, kind: .dispatch)
        try await reopened.resolveUnknown(operationID: operation.id)
        do { try await reopened.settle(operationID: operation.id, attemptID: operation.attemptID, outcome: .accepted(telemostTestConference())); XCTFail("late overwrite") } catch {}
        let final = try await reopened.operation(id: operation.id); XCTAssertEqual(final.state, .resolved)
        try await reopened.releaseLease(resolutionLease)
        _ = lease
    }
    func testProcessLeaseOwnership() async throws {
        let (db, repo) = try await setup()
        let op = UUID(), lease = try await repo.acquireLease(accountID: telemostTestAccountID, operationID: op, kind: .auth)
        let other = TelemostRepository(keyProvider: telemostTestKey); try await other.open(configuration: db.configuration)
        addTeardownBlock { await other.close() }
        do { _ = try await other.acquireLease(accountID: telemostTestAccountID, operationID: UUID(), kind: .dispatch); XCTFail("another owner admitted") }
        catch { XCTAssertEqual(error as? TelemostFailure, .busy) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", """
import ctypes,os
q=ctypes.CDLL(os.environ["TELEMOST_TEST_LIBPQ"])
q.PQconnectdb.argtypes=[ctypes.c_char_p];q.PQconnectdb.restype=ctypes.c_void_p
q.PQexec.argtypes=[ctypes.c_void_p,ctypes.c_char_p];q.PQexec.restype=ctypes.c_void_p
q.PQgetvalue.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int];q.PQgetvalue.restype=ctypes.c_char_p
q.PQclear.argtypes=[ctypes.c_void_p];q.PQfinish.argtypes=[ctypes.c_void_p]
c=q.PQconnectdb(os.environ["MAKOSH_TEST_DATABASE_URL"].encode())
assert c
r=q.PQexec(c,("SELECT pg_try_advisory_lock(hashtextextended('"+os.environ["TELEMOST_TEST_LOCK"]+"',0))").encode())
assert r and q.PQgetvalue(r,0,0)==b'f'
q.PQclear(r);q.PQfinish(c)
"""]
        var environment = ProcessInfo.processInfo.environment
        environment["TELEMOST_TEST_LOCK"] = db.configuration.schema + "/makosh-telemost-account/" + telemostTestAccountID.uuidString
        environment["TELEMOST_TEST_LIBPQ"] = FileManager.default.currentDirectoryPath + "/.local/postgres-client/lib/libpq.5.dylib"
        process.environment = environment; process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        try await repo.releaseLease(lease)
        let available = try await other.acquireLease(accountID: telemostTestAccountID, operationID: UUID(), kind: .dispatch)
        try await other.releaseLease(available)
    }
    func testImmutableAttemptAndDefinitiveSettlement() async throws {
        let (_, repo) = try await setup()
        let operation = TelemostOperation(accountID: telemostTestAccountID, payload: .create(.init(waitingRoom: .admins)))
        try await repo.prepare(operation)
        let lease = try await repo.acquireLease(accountID: operation.accountID, operationID: operation.id, kind: .dispatch)
        do { _ = try await repo.begin(operationID: operation.id, attemptID: UUID()); XCTFail("wrong attempt") } catch {}
        _ = try await repo.begin(operationID: operation.id, attemptID: operation.attemptID)
        try await repo.settle(operationID: operation.id, attemptID: operation.attemptID, outcome: .rejected(403))
        let stored = try await repo.operation(id: operation.id); XCTAssertEqual(stored.state, .rejected); XCTAssertEqual(stored.rejectionStatus, 403)
        do { _ = try await repo.begin(operationID: operation.id, attemptID: operation.attemptID); XCTFail("settled attempt replay") } catch {}
        try await repo.releaseLease(lease)
    }
    func testOpenDoesNotRecoverLiveDispatchOwner() async throws {
        let (db, repo) = try await setup()
        let operation = TelemostOperation(accountID: telemostTestAccountID, payload: .create(.init(waitingRoom: .admins)))
        try await repo.prepare(operation)
        let lease = try await repo.acquireLease(accountID: operation.accountID, operationID: operation.id, kind: .dispatch)
        _ = try await repo.begin(operationID: operation.id, attemptID: operation.attemptID)
        let other = TelemostRepository(keyProvider: telemostTestKey)
        try await other.open(configuration: db.configuration); addTeardownBlock { await other.close() }
        let current = try await other.operation(id: operation.id)
        XCTAssertEqual(current.state, .dispatching)
        try await repo.releaseLease(lease)
    }
}

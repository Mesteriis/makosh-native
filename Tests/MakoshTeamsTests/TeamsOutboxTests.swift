import XCTest
import MakoshCore
@testable import MakoshTeams
@testable import MakoshApp

@MainActor
final class TeamsOutboxTests: XCTestCase {
    func database() throws -> TeamsTestDatabase { let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }; return db }
    func testManualReceiptIsNotPresentedAsGraphAcceptance() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let outgoing = try await repository.prepareOutgoing(scope: teamsTestScope, content: TeamsDraft(text: "unknown"))
        let attempt = try await repository.claimOutgoing(id: outgoing.id, accountID: outgoing.scope.accountID)
        _ = try await repository.settleOutgoing(id: outgoing.id, accountID: outgoing.scope.accountID, attemptID: try XCTUnwrap(attempt.attemptID), outcome: .unknown)
        let resolved = try await repository.resolveOutgoing(id: outgoing.id, accountID: outgoing.scope.accountID, sent: true)
        XCTAssertEqual(teamsOutgoingTitle(resolved, synthetic: false), "Отмечено вами как отправленное")
        XCTAssertEqual(teamsOutgoingTitle(resolved, synthetic: true), "Отмечено вами как отправленное")
        await repository.close()
    }
    func testLiveOwnerAndLateAttemptCannotBeResolvedOrOverwriteReceipt() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let prepared = try await repository.prepareOutgoing(scope: teamsTestScope, content: TeamsDraft(text: "captured"))
        let claimed = try await repository.claimOutgoing(id: prepared.id, accountID: teamsTestContext.accountID)
        let other = TeamsRepository(keyProvider: teamsTestKey); try await other.open(configuration: db.configuration)
        do { _ = try await other.resolveOutgoing(id: prepared.id, accountID: teamsTestContext.accountID, sent: false); XCTFail("Live owner resolved") }
        catch let error as TeamsFailure { XCTAssertEqual(error, .operationBusy) }
        do {
            _ = try await repository.settleOutgoing(id: prepared.id, accountID: teamsTestContext.accountID, attemptID: UUID(), outcome: .unknown)
            XCTFail("Wrong attempt settled")
        } catch let error as TeamsFailure { XCTAssertEqual(error, .operationBusy) }
        _ = try await repository.settleOutgoing(id: prepared.id, accountID: teamsTestContext.accountID, attemptID: try XCTUnwrap(claimed.attemptID), outcome: .unknown)
        let resolved = try await other.resolveOutgoing(id: prepared.id, accountID: teamsTestContext.accountID, sent: false)
        XCTAssertEqual(resolved.state, .notSent)
        do {
            _ = try await repository.settleOutgoing(id: prepared.id, accountID: teamsTestContext.accountID, attemptID: try XCTUnwrap(claimed.attemptID), outcome: .accepted(teamsTestMessage("late")))
            XCTFail("Late completion overwrote explicit receipt")
        } catch let error as TeamsFailure { XCTAssertEqual(error, .operationBusy) }
        let current = try await other.outgoing(id: prepared.id, accountID: teamsTestContext.accountID)
        XCTAssertEqual(current.state, .notSent)
        XCTAssertEqual(current.content.text, "captured")
        await repository.close(); await other.close()
    }
    func testUnownedDispatchingAttemptRecoversAsUnknownAndCannotResume() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let prepared = try await repository.prepareOutgoing(scope: teamsTestScope, content: TeamsDraft(text: "do not replay"))
        let claimed = try await repository.claimOutgoing(id: prepared.id, accountID: teamsTestContext.accountID)
        await repository.close()
        let reopened = TeamsRepository(keyProvider: teamsTestKey); try await reopened.open(configuration: db.configuration)
        let restored = try await reopened.outgoing(id: prepared.id, accountID: teamsTestContext.accountID)
        XCTAssertEqual(restored.state, .unknown)
        XCTAssertEqual(restored.attemptID, claimed.attemptID)
        do { _ = try await reopened.claimOutgoing(id: prepared.id, accountID: teamsTestContext.accountID); XCTFail("Replayed orphan") }
        catch let error as TeamsFailure { XCTAssertEqual(error, .uncertainSubmission) }
        await reopened.close()
    }
    func testOutboxPagesDoNotDecodeLifetimeHistory() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        var prepared: TeamsOutgoing?
        for i in 0..<60 { prepared = try await repository.prepareOutgoing(scope: teamsTestScope, content: TeamsDraft(text: "item \(i)")) }
        try db.execute("UPDATE \"\(db.configuration.schema)\".teams_outbox SET ciphertext='corrupt' WHERE sequence=(SELECT min(sequence) FROM \"\(db.configuration.schema)\".teams_outbox)")
        let page = try await repository.outgoingPage(accountID: teamsTestContext.accountID, before: nil, limit: 50)
        XCTAssertEqual(page.values.count, 50); XCTAssertNotNil(page.next)
        let last = try XCTUnwrap(prepared)
        let claimed = try await repository.claimOutgoing(id: last.id, accountID: teamsTestContext.accountID)
        let accepted = try await repository.settleOutgoing(id: last.id, accountID: teamsTestContext.accountID, attemptID: try XCTUnwrap(claimed.attemptID), outcome: .accepted(teamsTestMessage("provider accepted", id: "remote-id")))
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertEqual(accepted.receipt?.providerMessageID, "remote-id")
        let jobs = try await repository.pendingProjection(limit: 50)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.observation.source, .outgoing)
        await repository.close()
    }
}

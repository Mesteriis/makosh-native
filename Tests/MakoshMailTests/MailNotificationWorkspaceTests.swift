import XCTest
import CPostgres
import MakoshCore
import MakoshMail
@testable import MakoshApp

@MainActor final class MailNotificationWorkspaceTests: XCTestCase {
    private func configuration() throws -> ContactWorkspaceConfiguration {
        guard let dsn=ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PostgreSQL required") }
        return .init(connectionString:dsn,schema:"qa_mail_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased())
    }
    func testSyntheticModeRejectsSharedArchiveSchema() async throws {
        let isolated=try configuration()
        let model=MailWorkspaceModel(synthetic:true)
        await model.load(configuration:.init(connectionString:isolated.connectionString,schema:isolated.schema,archiveSchema:"makosh"))
        XCTAssertFalse(model.ready);XCTAssertTrue(model.accounts.isEmpty)
    }
    func testSyntheticIncomingUsesPersistentPolicyAndDoesNotNotifyOnLoad() async throws {
        let config=try configuration(),model=MailWorkspaceModel(synthetic:true)
        await model.load(configuration:config);XCTAssertNil(model.notifications.delivery)
        XCTAssertEqual(model.selectedFolder?.kind,.inbox)
        let account=try XCTUnwrap(model.accounts.first)
        await model.setNotificationRule(scope:.sender(accountID:account.id,address:"team@example.invalid"),rule:.init(enabled:false))
        await model.simulateIncoming();XCTAssertNil(model.notifications.delivery)
        await model.setNotificationRule(scope:.sender(accountID:account.id,address:"team@example.invalid"),rule:nil)
        await model.simulateIncoming()
        let delivery=try XCTUnwrap(model.notifications.delivery)
        XCTAssertEqual(delivery.event.key.accountID,account.id)
        await model.handleNotificationAction(.open,event:delivery.event)
        XCTAssertEqual(model.selectedID,delivery.id);XCTAssertFalse(model.showArchive)
        let reopened=MailWorkspaceModel(synthetic:true);await reopened.load(configuration:config)
        XCTAssertNil(reopened.notifications.delivery)
        await reopened.setNotificationRule(scope:.account(account.id),rule:.init(previews:false,sound:false))
        let third=MailWorkspaceModel(synthetic:true);await third.load(configuration:config)
        XCTAssertEqual(third.notifications.preferences.overrides[MailNotificationScope.account(account.id).id],.init(previews:false,sound:false))
    }
    func testStaleNotificationCannotChangeSelectionAfterDisconnect() async throws {
        let model=MailWorkspaceModel(synthetic:true);await model.load(configuration:try configuration())
        await model.simulateIncoming();let event=try XCTUnwrap(model.notifications.delivery?.event)
        await model.disconnect(try XCTUnwrap(model.accounts.first))
        model.selectArchive();await model.handleNotificationAction(.open,event:event)
        XCTAssertTrue(model.showArchive);XCTAssertNil(model.selectedID)
    }
    func testSettingsChangeInAnotherWindowInvalidatesExistingRoute() async throws {
        let config=try configuration(),a=MailWorkspaceModel(synthetic:true),b=MailWorkspaceModel(synthetic:true)
        await a.load(configuration:config);await b.load(configuration:config)
        await a.simulateIncoming();let event=try XCTUnwrap(a.notifications.delivery?.event)
        XCTAssertTrue(a.notifications.canPresent(identifier:event.id))
        await b.setNotificationRule(scope:.sender(accountID:event.key.accountID,address:event.sender),rule:.init(enabled:false))
        let deadline=ContinuousClock.now.advanced(by:.seconds(1))
        while a.notifications.canPresent(identifier:event.id),ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(a.notifications.canPresent(identifier:event.id))
    }
    func testForegroundActivationDoesNotCancelExistingCardAction() async throws {
        let model=MailWorkspaceModel(synthetic:true);await model.load(configuration:try configuration())
        await model.setNotificationRule(scope:.global,rule:.init(),showWhileActive:false)
        await model.simulateIncoming();let event=try XCTUnwrap(model.notifications.delivery?.event)
        model.notifications.setPresentationEnvironment(active:true,locked:false)
        await model.handleNotificationAction(.open,event:event)
        XCTAssertEqual(model.selectedID,event.id)
    }
    func testBusyActionWaitsForLocalOperationAndOpensOnceIdle() async throws {
        let config=try configuration(),model=MailWorkspaceModel(synthetic:true)
        await model.load(configuration:config);await model.simulateIncoming()
        let event=try XCTUnwrap(model.notifications.delivery?.event),lock=try MailStateLock(config)
        let saving=Task { await model.setNotificationRule(scope:.sender(accountID:event.key.accountID,address:"other@example.invalid"),rule:.init(sound:false)) }
        await waitUntil { model.busy && lock.hasWaitingWriter() }
        await model.handleNotificationAction(.open,event:event)
        lock.release();await saving.value
        await waitUntil { model.selectedID == event.id }
        XCTAssertEqual(model.selectedID,event.id)
    }
    func testOverlappingReloadsDoNotDiscardDestructivelyConsumedEvents() async throws {
        let config=try configuration(),model=MailWorkspaceModel(synthetic:true)
        await model.load(configuration:config)
        let folder=try XCTUnwrap(model.folders.first { $0.kind == .inbox })
        let repository=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:0x73,count:32)})
        let letter=MailLetter(key:.init(accountID:folder.accountID,folder:folder.path,uidValidity:folder.uidValidity ?? 42,uid:100),subject:"New during reload",senderName:"QA",sender:"team@example.invalid",recipient:"qa@example.invalid",date:Date())
        try await repository.savePage([letter],folder:folder,uidValidity:letter.key.uidValidity,notifyIncoming:true)
        let lock=try MailStateLock(config)
        let first=Task { try await model.reload() }
        await waitUntil { lock.hasWaitingWriter() }
        var secondStarted=false
        let second=Task { secondStarted=true;try await model.reload() }
        await waitUntil { secondStarted }
        lock.release();try await first.value;try await second.value
        XCTAssertEqual(model.notifications.delivery?.id,letter.id)
    }
    private func waitUntil(_ condition:() -> Bool) async {
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        while !condition(),ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(),"Fixture did not reach the required interleaving")
    }
}

private final class MailStateLock {
    private let connection:OpaquePointer
    private let schema:String
    private var held=true
    init(_ configuration:ContactWorkspaceConfiguration) throws {
        schema=configuration.schema
        guard let connection=PQconnectdb(configuration.connectionString),PQstatus(connection)==CONNECTION_OK else { throw MailFailure.storage }
        self.connection=connection
        try execute("BEGIN");try execute("SELECT id FROM \"\(schema)\".mail_state WHERE id=1 FOR UPDATE")
    }
    deinit { release();PQfinish(connection) }
    func release() { if held { held=false;try? execute("ROLLBACK") } }
    func hasWaitingWriter() -> Bool {
        try? execute("SELECT pg_stat_clear_snapshot()")
        let sql="SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%\(schema)%mail_state%FOR UPDATE%'"
        guard let result=PQexec(connection,sql) else { return false };defer { PQclear(result) }
        return PQresultStatus(result)==PGRES_TUPLES_OK && PQntuples(result)==1 && (Int(String(cString:PQgetvalue(result,0,0))) ?? 0) > 0
    }
    private func execute(_ sql:String) throws {
        guard let result=PQexec(connection,sql) else { throw MailFailure.storage };defer { PQclear(result) }
        guard [PGRES_COMMAND_OK,PGRES_TUPLES_OK].contains(PQresultStatus(result)) else { throw MailFailure.storage }
    }
}

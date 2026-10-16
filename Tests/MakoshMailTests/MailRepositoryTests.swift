import XCTest
import CPostgres
import MakoshCore
@testable import MakoshMail

final class MailRepositoryTests: XCTestCase {
    private func configuration() throws -> ContactWorkspaceConfiguration {
        guard let dsn=ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("Real PostgreSQL test configuration required") }
        return .init(connectionString:dsn,schema:"qa_mail_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased())
    }
    private func account() -> MailAccount { .init(displayName:"QA",email:"qa@example.invalid",imapHost:"imap.example.invalid",imapUsername:"qa",smtpHost:"smtp.example.invalid",smtpUsername:"qa") }
    func testMessageIdentityIncludesAccountFolderValidityAndUID() {
        let key=MailMessageKey(accountID:"a",folder:"INBOX",uidValidity:97,uid:11)
        XCTAssertNotEqual(key.id,MailMessageKey(accountID:"b",folder:"INBOX",uidValidity:97,uid:11).id)
        XCTAssertNotEqual(key.id,MailMessageKey(accountID:"a",folder:"INBOX",uidValidity:98,uid:11).id)
        XCTAssertEqual(key.id,MailMessageKey(accountID:"a",folder:"inbox",uidValidity:97,uid:11).id)
        XCTAssertNotEqual(MailMessageKey(accountID:"a",folder:"Sent",uidValidity:97,uid:11).id,MailMessageKey(accountID:"a",folder:"sent",uidValidity:97,uid:11).id)
    }
    func testHeaderInjectionAndInvalidRecipientAreRejected() {
        XCTAssertThrowsError(try MailDraft(accountID:"a",to:"peer@example.invalid\r\nBcc:other@example.invalid").validate())
        XCTAssertThrowsError(try MailDraft(accountID:"a",to:"peer@example.invalid",subject:"x\r\ny").validate())
        XCTAssertNoThrow(try MailDraft(accountID:"a",to:"peer@example.invalid, second@example.invalid",bcc:"hidden@example.invalid").validate())
    }
    func testTwoConnectionsPreserveIndependentAccountWrites() async throws {
        let config=try configuration()
        let first=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:7,count:32)})
        let second=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:7,count:32)})
        let a=account(),b=account()
        async let one:Void=first.saveAccount(a)
        async let two:Void=second.saveAccount(b)
        _=try await (one,two)
        let snapshot=try await first.snapshot()
        XCTAssertEqual(Set(snapshot.accounts.map(\.id)),Set([a.id,b.id]))
    }
    func testBodiesAndOldUIDValiditySurviveHeaderSyncAndReopen() async throws {
        let config=try configuration(),account=account()
        let first=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:8,count:32)})
        try await first.saveAccount(account)
        let key=MailMessageKey(accountID:account.id,folder:"INBOX",uidValidity:97,uid:11)
        let letter=MailLetter(key:key,subject:"Body",senderName:"Sender",sender:"sender@example.invalid",recipient:account.email,date:Date(),text:"Retain me",html:"<b>Retain me</b>",attachments:[.init(id:"0",filename:"file.bin",mimeType:"application/octet-stream",byteCount:4)])
        try await first.saveLetters([letter])
        var header=letter;header.text=nil;header.html=nil;header.attachments=[];header.flagged=true
        try await first.saveLetters([header])
        var newValidity=header;newValidity.key = .init(accountID:account.id,folder:"INBOX",uidValidity:98,uid:11)
        try await first.saveLetters([newValidity])
        let reopened=MailRepository(configuration:config,keyProvider:{_,create in XCTAssertFalse(create);return Data(repeating:8,count:32)})
        let snapshot=try await reopened.snapshot()
        XCTAssertEqual(snapshot.letters.count,2)
        let retained=try XCTUnwrap(snapshot.letters.first { $0.key==key })
        XCTAssertEqual(retained.text,"Retain me");XCTAssertEqual(retained.attachments.count,1);XCTAssertTrue(retained.flagged)
    }
    func testSubmissionAdmissionSurvivesRestartAndRequiresExplicitResolution() async throws {
        let config=try configuration(),account=account()
        let first=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:9,count:32)})
        try await first.saveAccount(account)
        let draft=MailDraft(accountID:account.id,to:"peer@example.invalid",subject:"Unknown",body:"Retain me")
        try await first.saveDraft(draft)
        let submission=MailSubmission(draftID:draft.id,accountID:account.id,state:.submitting)
        try await first.admit(submission)
        let reopened=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:9,count:32)})
        do { try await reopened.admit(.init(draftID:draft.id,accountID:account.id,state:.submitting));XCTFail("Unknown admission cannot be replayed") } catch { XCTAssertEqual(error as? MailFailure,.unknownSubmission) }
        // Simulate the previous process ending its live attempt before recovery.
        await first.endSubmissionAttempt(submission.id)
        try await reopened.resolveUnknown(submission.id,wasSent:false)
        try await reopened.admit(.init(draftID:draft.id,accountID:account.id,state:.submitting))
        let snapshot=try await reopened.snapshot();XCTAssertEqual(snapshot.submissions.count,2);XCTAssertEqual(snapshot.drafts.count,1)
    }
    func testFolderCachePastGlobalSnapshotAndHiddenGenerationPaging() async throws {
        let config = try configuration(), a = account()
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 12, count: 32) })
        let folder = MailFolder(accountID: a.id, path: "Old", kind: .other, uidValidity: 99)
        func letter(_ uid: UInt32, validity: UInt32 = 99, path: String = "Old", removed: Bool = false) -> MailLetter {
            var value = MailLetter(key: .init(accountID: a.id, folder: path, uidValidity: validity, uid: uid), subject: "Cached", senderName: "QA", sender: "qa@example.invalid", recipient: a.email, date: Date())
            value.removedFromSource = removed; return value
        }
        try await repository.saveLetters([letter(1), letter(2)])
        try await repository.saveLetters((3...1020).map { letter(UInt32($0), path: "INBOX") })
        let snapshot = try await repository.snapshot()
        XCTAssertFalse(snapshot.letters.contains { $0.key.folder == "Old" })
        try await repository.saveLetters((3...60).map { letter(UInt32($0), validity: 98) } + [letter(61, removed: true)])
        let page = try await repository.cachedPage(folder: folder, beforeSequence: nil, limit: 1)
        XCTAssertEqual(page.map(\.key.uid), [2])
        let older = try await repository.cachedPage(folder: folder, beforeSequence: page.first?.cacheSequence, limit: 1)
        XCTAssertEqual(older.map(\.key.uid), [1])
        let archive = try await repository.cachedPage(folder: nil, beforeSequence: nil, limit: 1000)
        XCTAssertTrue(archive.contains { $0.removedFromSource == true })
        XCTAssertTrue(archive.contains { $0.key.uidValidity == 98 })
    }
    func testDraftAppendAdmissionSurvivesRestartAndCannotBeClearedBySaving() async throws {
        let config = try configuration(), a = account()
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 13, count: 32) })
        let draft = MailDraft(accountID: a.id, subject: "Incomplete draft", body: "Body")
        try await repository.saveDraft(draft)
        let admitted = try await repository.admitDraftAppend(draft.id, digest: "one"); XCTAssertNotNil(admitted)
        let reopened = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 13, count: 32) })
        try await reopened.saveDraft(draft)
        do { _ = try await reopened.admitDraftAppend(draft.id, digest: "two"); XCTFail("No replay after restart or edit") }
        catch { XCTAssertEqual(error as? MailFailure, .unknownDraftSave) }
        try await reopened.updateDraftRemoteSave(draft.id, expected: try XCTUnwrap(admitted), state: .userConfirmedSaved)
        let same = try await reopened.admitDraftAppend(draft.id, digest: "one"); XCTAssertNil(same)
        let changed = try await reopened.admitDraftAppend(draft.id, digest: "two"); XCTAssertNotNil(changed)
        do { try await reopened.updateDraftRemoteSave(draft.id, expected: try XCTUnwrap(admitted), state: .saved); XCTFail("Old completion cannot settle a new attempt") } catch { XCTAssertEqual(error as? MailFailure, .invalidInput) }
        let state = try await reopened.snapshot(); XCTAssertEqual(state.drafts.first?.remoteSave, changed)
    }
    func testFullBodyVersionsRemainAppendOnlyAfterLaterEdits() async throws {
        let config = try configuration(), a = account()
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 14, count: 32) })
        var value = MailLetter(key: .init(accountID: a.id, folder: "INBOX", uidValidity: 1, uid: 1), subject: "History", senderName: "QA", sender: a.email, recipient: a.email, date: Date(), text: "First")
        try await repository.saveLetters([value]); value.text = "Second"; try await repository.saveLetters([value])
        try verifyVersions(config)
    }
    private func verifyVersions(_ config: ContactWorkspaceConfiguration) throws {
        let connection = try XCTUnwrap(config.connectionString.withCString { PQconnectdb($0) }); defer { PQfinish(connection) }
        XCTAssertEqual(PQstatus(connection), CONNECTION_OK)
        let table = "\"\(config.schema)\".mail_letter_versions"
        let count = try XCTUnwrap(PQexec(connection, "SELECT count(*) FROM " + table)); defer { PQclear(count) }
        XCTAssertEqual(PQresultStatus(count), PGRES_TUPLES_OK)
        XCTAssertEqual(String(cString: PQgetvalue(count, 0, 0)), "2")
        for statement in ["UPDATE " + table + " SET ciphertext='replacement'", "DELETE FROM " + table, "TRUNCATE " + table] {
            let result = try XCTUnwrap(PQexec(connection, statement)); defer { PQclear(result) }
            XCTAssertEqual(PQresultStatus(result), PGRES_FATAL_ERROR, "Historical versions must refuse mutation")
        }
    }
    func testWrongKeyDoesNotOverwriteExistingState() async throws {
        let config=try configuration(),account=account()
        let first=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:10,count:32)})
        try await first.saveAccount(account)
        let wrong=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:11,count:32)})
        do { _=try await wrong.snapshot();XCTFail("Must not replace key") } catch {}
        let snapshot=try await first.snapshot();XCTAssertEqual(snapshot.accounts.count,1)
    }
}

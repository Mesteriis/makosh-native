import XCTest
import MakoshCore
@testable import MakoshMail

final class MailWorkerTests: XCTestCase {
    private func configuration() throws -> ContactWorkspaceConfiguration {
        guard let dsn=ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("Real PostgreSQL required") }
        return .init(connectionString:dsn,schema:"qa_mail_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased())
    }
    private func account(_ fixture: Fixture) -> MailAccount {
        .init(displayName:"QA",email:"qa@example.invalid",imapHost:"localhost",imapPort:fixture.config.imapPort,imapSecurity:.startTLS,imapUsername:"qa",smtpHost:"localhost",smtpPort:fixture.config.smtpPort,smtpSecurity:.startTLS,smtpUsername:"qa")
    }
    func testRemoteDraftSavedOnceAndReopensInComposerData() async throws {
        guard let storage = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("S3 required") }
        let fixture = try await Fixture(mode: "imap", scenario: "draft-starttls"); defer { fixture.close() }
        let config = try configuration(), a = account(fixture)
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x21, count: 32) })
        let worker = MailAccountWorker(account: a, repository: repository, configuration: config, storageFile: URL(fileURLWithPath: storage), spool: fixture.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x21, count: 32) }, tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path)
        let folders = try await worker.connect()
        let draft = MailDraft(accountID: a.id, to: "peer@example.invalid", bcc: "hidden@example.invalid", subject: "Saved", body: "Body")
        let saved = try await worker.saveDraft(draft, attachmentFiles: []); XCTAssertEqual(saved.remoteSave?.state, .saved)
        _ = try await worker.saveDraft(saved, attachmentFiles: [])
        let folder = try XCTUnwrap(folders.first { $0.kind == .drafts })
        try await worker.setFileSaving(folder: folder, enabled: false)
        let page = try await worker.page(folder: folder); let letter = try XCTUnwrap(page.first)
        let full = try await worker.body(letter)
        _ = try await worker.page(folder: folder)
        let other = MailLetter(key: .init(accountID: a.id, folder: "INBOX", uidValidity: 97, uid: 11), subject: "Other", senderName: "QA", sender: a.email, recipient: a.email, date: Date())
        _ = try await worker.body(other) // Evict the Drafts memory tuple before recovery.
        let edited = try await worker.editRemoteDraft(full); XCTAssertEqual(edited.accountID, a.id); XCTAssertEqual(edited.body, "Mail fixture body")
        XCTAssertEqual(edited.to, "qa@example.invalid, second@example.invalid")
        XCTAssertEqual(edited.cc, "copy@example.invalid"); XCTAssertEqual(edited.bcc, "hidden@example.invalid")
        XCTAssertEqual(edited.files.map(\.filename), ["same.bin", "same.bin"])
        XCTAssertTrue(edited.files.allSatisfy { $0.record.state == .local })
        XCTAssertEqual(edited.bodyHTML, "<p><strong>Mail fixture body</strong></p>")
        await worker.disconnect()
        let count = try await fixture.count("append"); XCTAssertEqual(count, 1)
        let fetches = try await fixture.count("body_fetch"); XCTAssertEqual(fetches, 3)
    }
    func testDraftRecoveryPrefersDurableS3BeforeConnectedServerFetch() async throws {
        guard let storage = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("S3 required") }
        let fixture = try await Fixture(mode: "imap", scenario: "draft-starttls"); defer { fixture.close() }
        let config = try configuration(), a = account(fixture)
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x24, count: 32) })
        let worker = MailAccountWorker(account: a, repository: repository, configuration: config, storageFile: URL(fileURLWithPath: storage), spool: fixture.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x24, count: 32) }, tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path)
        let folders = try await worker.connect(), folder = try XCTUnwrap(folders.first { $0.kind == .drafts })
        let page = try await worker.page(folder: folder), full = try await worker.body(XCTUnwrap(page.first))
        let other = MailLetter(key: .init(accountID: a.id, folder: "INBOX", uidValidity: 97, uid: 11), subject: "Other", senderName: "QA", sender: a.email, recipient: a.email, date: Date())
        _ = try await worker.body(other)
        let edited = try await worker.editRemoteDraft(full); XCTAssertEqual(edited.files.count, 2)
        await worker.disconnect()
        let fetches = try await fixture.count("body_fetch"); XCTAssertEqual(fetches, 2, "Stored files must not require another server read")
    }
    func testConnectedExportRefetchesUnarchivedFileAfterMemoryCacheLoss() async throws {
        guard let storage = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("S3 required") }
        let fixture = try await Fixture(mode: "imap", scenario: "draft-starttls"); defer { fixture.close() }
        let config = try configuration(), a = account(fixture)
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x25, count: 32) })
        let worker = MailAccountWorker(account: a, repository: repository, configuration: config, storageFile: URL(fileURLWithPath: storage), spool: fixture.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x25, count: 32) }, tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path)
        let folders = try await worker.connect(), folder = try XCTUnwrap(folders.first { $0.kind == .drafts })
        try await worker.setFileSaving(folder: folder, enabled: false)
        let page = try await worker.page(folder: folder), full = try await worker.body(XCTUnwrap(page.first))
        let other = MailLetter(key: .init(accountID: a.id, folder: "INBOX", uidValidity: 97, uid: 11), subject: "Other", senderName: "QA", sender: a.email, recipient: a.email, date: Date())
        _ = try await worker.body(other)
        let destination = fixture.root.appendingPathComponent("download.bin")
        try await worker.exportAttachment(XCTUnwrap(full.attachments.first), letter: full, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1,2,3]))
        await worker.disconnect()
        let fetches = try await fixture.count("body_fetch"); XCTAssertEqual(fetches, 3)
    }
    func testCancelledDraftSaveDoesNotDispatchAPPENDOrPersistNewDraft() async throws {
        let fixture = try await Fixture(mode: "imap", scenario: "draft-starttls"); defer { fixture.close() }
        let config = try configuration(), a = account(fixture)
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x23, count: 32) })
        let worker = MailAccountWorker(account: a, repository: repository, configuration: config, storageFile: nil, spool: fixture.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x23, count: 32) }, tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path)
        _ = try await worker.connect()
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await worker.saveDraft(MailDraft(accountID: a.id, subject: "Cancelled"), attachmentFiles: []) }
        do { _ = try await task.value; XCTFail("Cancelled save must stop") } catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = try await repository.snapshot(); XCTAssertTrue(snapshot.drafts.isEmpty)
        await worker.disconnect(); let count = try await fixture.count("append"); XCTAssertEqual(count, 0)
    }
    func testRemoteDraftLossBlocksAPPENDReplay() async throws {
        let fixture = try await Fixture(mode: "imap", scenario: "draft-drop-starttls"); defer { fixture.close() }
        let config = try configuration(), a = account(fixture)
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x22, count: 32) })
        let worker = MailAccountWorker(account: a, repository: repository, configuration: config, storageFile: nil, spool: fixture.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x22, count: 32) }, tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path)
        _ = try await worker.connect()
        let draft = MailDraft(accountID: a.id, subject: "Unknown", body: "Body")
        for _ in 0..<2 {
            do { _ = try await worker.saveDraft(draft, attachmentFiles: []); XCTFail("No APPEND replay") }
            catch { XCTAssertEqual(error as? MailFailure, .unknownDraftSave) }
        }
        await worker.disconnect()
        let count = try await fixture.count("append"); XCTAssertEqual(count, 1)
    }
    func testWorkerReceivesBodyAndArchivesRawMessageInS3() async throws {
        guard let storage=ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("Real S3 required") }
        let fixture=try await Fixture(mode:"imap",scenario:"starttls");defer { fixture.close() }
        let config=try configuration(),account=account(fixture)
        let repository=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:0x19,count:32)})
        let worker=MailAccountWorker(account:account,repository:repository,configuration:config,storageFile:URL(fileURLWithPath:storage),spool:fixture.root.appendingPathComponent("spool"),credentials:.init(save:{_,_,_ in },read:{_,_ in "synthetic"}),keyProvider:{_,_ in Data(repeating:0x19,count:32)},tlsCAFile:fixture.root.appendingPathComponent("cert.pem").path)
        let folders=try await worker.connect();let folder=try XCTUnwrap(folders.first { $0.kind == .inbox })
        let page=try await worker.page(folder:folder);let letter=try XCTUnwrap(page.first)
        let body=try await worker.body(letter);XCTAssertEqual(body.text,"Mail fixture body")
        let files=try ArchiveFileRepository(connectionString:config.connectionString,schema:config.schema,configuration:S3ConfigurationFile.read(URL(fileURLWithPath:storage)),spoolDirectory:fixture.root.appendingPathComponent("spool"),keyProvider:{_,_ in Data(repeating:0x19,count:32)})
        let records=try await files.files(identity:letter.key.archiveIdentity,attachmentID:"rfc822-source")
        XCTAssertEqual(records.count,1);XCTAssertEqual(records.first?.state,.stored)
        let destination=fixture.root.appendingPathComponent("export.eml")
        try await files.export(try XCTUnwrap(records.first),to:destination)
        XCTAssertEqual(MIME.parse(try Data(contentsOf:destination)).text,"Mail fixture body")
        _=try await worker.body(letter)
        let deduplicated=try await files.files(identity:letter.key.archiveIdentity,attachmentID:"rfc822-source")
        XCTAssertEqual(deduplicated.count,1)
        await worker.disconnect()
    }
    func testFolderOffUsesEncryptedLocalDraftAndSurvivesReopenWithoutS3Copy() async throws {
        guard let storage=ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("Real S3 required") }
        let fixture=try await Fixture(mode:"imap",scenario:"starttls");defer { fixture.close() }
        let config=try configuration(),account=account(fixture),spool=fixture.root.appendingPathComponent("spool")
        let repository=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:0x20,count:32)})
        let worker=MailAccountWorker(account:account,repository:repository,configuration:config,storageFile:URL(fileURLWithPath:storage),spool:spool,credentials:.init(save:{_,_,_ in },read:{_,_ in "synthetic"}),keyProvider:{_,_ in Data(repeating:0x20,count:32)},tlsCAFile:fixture.root.appendingPathComponent("cert.pem").path)
        let folders=try await worker.connect();let folder=try XCTUnwrap(folders.first { $0.kind == .inbox })
        try await worker.setFileSaving(folder:folder,enabled:false)
        let page=try await worker.page(folder:folder);let letter=try XCTUnwrap(page.first);_=try await worker.body(letter)
        let files=try ArchiveFileRepository(connectionString:config.connectionString,schema:config.schema,configuration:S3ConfigurationFile.read(URL(fileURLWithPath:storage)),spoolDirectory:spool,keyProvider:{_,_ in Data(repeating:0x20,count:32)})
        let incoming=try await files.files(identity:letter.key.archiveIdentity,attachmentID:"rfc822-source");XCTAssertTrue(incoming.isEmpty)
        let payload=Data([0,255,128,1,2,3]);let input=fixture.root.appendingPathComponent("attachment.bin");try payload.write(to:input)
        let draft=MailDraft(accountID:account.id,to:"peer@example.invalid",subject:"Saved",body:"Text",sourceFolder:folder.path)
        let prepared=try await worker.prepareDraft(draft,attachmentFiles:[input])
        let record=try XCTUnwrap(prepared.files.first?.record);XCTAssertEqual(record.state,.local)
        let reopened=MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:0x20,count:32)})
        let snapshot=try await reopened.snapshot();XCTAssertEqual(snapshot.drafts.first?.files.first?.record,record)
        let exported=fixture.root.appendingPathComponent("recovered.bin");try await files.export(record,to:exported);XCTAssertEqual(try Data(contentsOf:exported),payload)
        let permanent=try await files.files(identity:record.identity,attachmentID:record.attachment.id);XCTAssertTrue(permanent.isEmpty)
        await worker.disconnect()
    }
}

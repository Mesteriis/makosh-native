import XCTest
import Darwin
import MakoshCore
@testable import MakoshTeams

@MainActor
final class TeamsFilesTests: XCTestCase {
    func fixture() async throws -> (TeamsTestDatabase, TeamsRepository, URL, S3ObjectStoreConfiguration) {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        try await repository.saveConversations([TeamsConversation(scope: teamsTestScope, displayName: "Personal", kind: .oneOnOne)],
            collection: TeamsCollection(context: teamsTestContext, kind: .chats), next: nil, failure: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        guard let path = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw TeamsFailure.invalidConfiguration }
        return (db, repository, root, try S3ConfigurationFile.read(URL(fileURLWithPath: path)))
    }
    func testWorkerFilePreparationAndPlanRemainBoundToScope() async throws {
        let (db, repository, root, storage) = try await fixture()
        let http = TeamsFileUploadHTTP()
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        try await vault.save(TeamsTokenBundle(accessToken: "synthetic", refreshToken: nil, idToken: nil, expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["User.Read", "Chat.Read", "ChatMessage.Send", "Files.ReadWrite"], expectedNonce: nil), accountID: teamsTestScope.accountID)
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        try await worker.configureFiles(storage: storage, spoolDirectory: root.appendingPathComponent("queue"))
        try await worker.setSavingFiles(scope: teamsTestScope, enabled: false)
        let source = root.appendingPathComponent("sample.txt"); try Data("file".utf8).write(to: source)
        let prepared = try await worker.prepareFiles(scope: teamsTestScope, files: [source])
        try await worker.connect(accountID: teamsTestScope.accountID)
        let plan = try await worker.fileAccessPlan(scope: teamsTestScope, fileIDs: prepared.map(\.id), destination: .ownDrive(folderID: "folder"))
        XCTAssertEqual(plan.recipients.map(\.displayName), ["Peer"])
        let result = try await worker.sendFiles(scope: teamsTestScope, content: TeamsDraft(text: "file", fileIDs: prepared.map(\.id)), accessPlan: plan)
        XCTAssertEqual(result.state, .unknown)
        await http.permitCompleteGrant()
        let newPlan = try await worker.fileAccessPlan(scope: teamsTestScope, fileIDs: prepared.map(\.id), destination: .ownDrive(folderID: "folder"))
        let accepted = try await worker.sendFiles(scope: teamsTestScope, content: TeamsDraft(text: "<file>", fileIDs: prepared.map(\.id)), accessPlan: newPlan)
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertEqual(accepted.fileSubmission?.stages.map(\.state), [.uploading, .uploaded, .granting, .granted, .publishing])
        let retained = try await repository.versions(scope: teamsTestScope, messageID: "accepted-file")
        XCTAssertEqual(retained.first?.message.attachments.count, 1)
        XCTAssertTrue(retained.first?.message.body.contains("&lt;file&gt;") == true)
        await worker.shutdown()
    }
    func testAcceptedOwnAttachmentReopensOfflineAndAfterRestart() async throws {
        let (db, repository, root, storage) = try await fixture()
        let http = TeamsFileUploadHTTP()
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        try await vault.save(TeamsTokenBundle(accessToken: "synthetic", refreshToken: nil, idToken: nil, expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["User.Read", "Chat.Read", "ChatMessage.Send", "Files.ReadWrite"], expectedNonce: nil), accountID: teamsTestScope.accountID)
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        try await worker.configureFiles(storage: storage, spoolDirectory: root.appendingPathComponent("queue"))
        try await worker.setSavingFiles(scope: teamsTestScope, enabled: false)
        let source = root.appendingPathComponent("sample.txt"); try Data("file".utf8).write(to: source)
        let prepared = try await worker.prepareFiles(scope: teamsTestScope, files: [source])
        try await worker.connect(accountID: teamsTestScope.accountID)
        let plan = try await worker.fileAccessPlan(scope: teamsTestScope, fileIDs: prepared.map(\.id), destination: .ownDrive(folderID: "folder"))
        XCTAssertEqual(plan.recipients.map(\.displayName), ["Peer"])
        let result = try await worker.sendFiles(scope: teamsTestScope, content: TeamsDraft(text: "file", fileIDs: prepared.map(\.id)), accessPlan: plan)
        XCTAssertEqual(result.state, .unknown)
        await http.permitCompleteGrant()
        let newPlan = try await worker.fileAccessPlan(scope: teamsTestScope, fileIDs: prepared.map(\.id), destination: .ownDrive(folderID: "folder"))
        await http.echoInto(repository)
        let accepted = try await worker.sendFiles(scope: teamsTestScope, content: TeamsDraft(text: "<file>", fileIDs: prepared.map(\.id)), accessPlan: newPlan)
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertEqual(accepted.fileSubmission?.stages.map(\.state), [.uploading, .uploaded, .granting, .granted, .publishing])
        let retained = try await repository.versions(scope: teamsTestScope, messageID: "accepted-file")
        XCTAssertEqual(retained.first?.message.attachments.count, 1)
        XCTAssertTrue(retained.first?.message.body.contains("&lt;file&gt;") == true)
        try await worker.disconnect(accountID: teamsTestScope.accountID)
        let version = try XCTUnwrap(retained.first)
        let attachment = try XCTUnwrap(version.message.attachments.first)
        let offline = try await worker.download(scope: teamsTestScope, messageID: version.message.id, attachmentID: attachment.id, version: String(version.sequence))
        XCTAssertEqual(try Data(contentsOf: offline.url), Data("file".utf8)); await offline.release()
        await worker.shutdown()
        let reopenedRepository = TeamsRepository(keyProvider: teamsTestKey)
        let reopened = TeamsWorker(repository: reopenedRepository, transport: TeamsScriptedHTTP([]), vault: TeamsTokenVault(api: TeamsFakeKeychain()), automaticSync: false)
        _ = try await reopened.load(configuration: db.configuration)
        try await reopened.configureFiles(storage: storage, spoolDirectory: root.appendingPathComponent("queue"))
        let restored = try await reopened.download(scope: teamsTestScope, messageID: version.message.id, attachmentID: attachment.id, version: String(version.sequence))
        XCTAssertEqual(try Data(contentsOf: restored.url), Data("file".utf8)); await restored.release()
        let stored = try await reopenedRepository.preparedFiles(scope: teamsTestScope, ids: prepared.map(\.id))
        XCTAssertEqual(stored.first?.archiveReceipt?.state, .local, "S3 OFF original remains local")
        await reopened.shutdown()
    }
    func testChannelUploadUsesInheritedAccessWithoutInvite() async throws {
        let (db, repository, root, storage) = try await fixture()
        let scope = TeamsScope(accountID: teamsTestScope.accountID, tenantID: teamsTestScope.tenantID, resource: .channel(teamID: "team", channelID: "channel"))
        let http = TeamsFileUploadHTTP(); await http.useChannel()
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        try await vault.save(TeamsTokenBundle(accessToken: "synthetic", refreshToken: nil, idToken: nil, expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["User.Read", "Chat.Read", "ChannelMessage.Send", "ChannelMember.Read.All", "Files.ReadWrite.All"], expectedNonce: nil), accountID: teamsTestScope.accountID)
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        try await worker.configureFiles(storage: storage, spoolDirectory: root.appendingPathComponent("queue"))
        try await worker.setSavingFiles(scope: scope, enabled: false)
        let source = root.appendingPathComponent("sample.txt"); try Data("file".utf8).write(to: source)
        let prepared = try await worker.prepareFiles(scope: scope, files: [source])
        try await worker.connect(accountID: teamsTestScope.accountID)
        let plan = try await worker.fileAccessPlan(scope: scope, fileIDs: prepared.map(\.id), destination: .channel(teamID: "team", channelID: "channel"))
        XCTAssertEqual(plan.recipients.map(\.displayName), ["Peer"])
        await http.useChannel(); await http.permitCompleteGrant()
        let accepted = try await worker.sendFiles(scope: scope, content: TeamsDraft(text: "channel file", fileIDs: prepared.map(\.id)), accessPlan: plan)
        XCTAssertEqual(accepted.state, .accepted)
        let requests = await http.requests
        XCTAssertTrue(requests.filter { $0.url?.path.hasSuffix("/invite") == true }.isEmpty, "Channel access is inherited, no durable direct user grants")
        await worker.shutdown()
    }
    func testTenFilesSurviveReopenAndEleventhIsRejectedBeforeIO() async throws {
        let (db, repository, root, storage) = try await fixture()
        let spool = root.appendingPathComponent("queue")
        let service = TeamsFiles(configuration: db.configuration, repository: repository, storage: storage, spoolDirectory: spool, keyProvider: teamsTestKey)
        var urls: [URL] = []
        for i in 0..<10 {
            let file = root.appendingPathComponent("file-\(i).txt")
            try Data("synthetic file \(i)".utf8).write(to: file)
            urls.append(file)
        }
        let prepared = try await service.prepare(scope: teamsTestScope, files: urls)
        XCTAssertEqual(prepared.count, 10)
        XCTAssertTrue(prepared.allSatisfy { $0.archiveReceipt?.state == .stored })
        let reopened = TeamsFiles(configuration: db.configuration, repository: repository, storage: storage, spoolDirectory: spool, keyProvider: teamsTestKey)
        let restored = try await reopened.prepared(scope: teamsTestScope, ids: prepared.map(\.id))
        XCTAssertEqual(restored.map(\.id), prepared.map(\.id))
        let lease = try await reopened.openPrepared(scope: teamsTestScope, id: restored[7].id)
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("synthetic file 7".utf8))
        await lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))

        let rejectedSpool = root.appendingPathComponent("must-not-exist")
        let guarded = TeamsFiles(configuration: db.configuration, repository: repository, storage: storage, spoolDirectory: rejectedSpool,
            keyProvider: { _, _ in XCTFail("Admission guard must precede key access"); return Data(repeating: 0, count: 32) })
        do { _ = try await guarded.prepare(scope: teamsTestScope, files: Array(repeating: root.appendingPathComponent("missing"), count: 11)); XCTFail("Eleventh file admitted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .invalidResource) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedSpool.path))
        await repository.close()
    }
    func testOversizeAndSymlinkAreRejected() async throws {
        let (db, repository, root, storage) = try await fixture()
        let service = TeamsFiles(configuration: db.configuration, repository: repository, storage: storage, spoolDirectory: root.appendingPathComponent("queue"), keyProvider: teamsTestKey)
        let source = root.appendingPathComponent("sparse")
        let fd = Darwin.open(source.path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 100 * 1024 * 1024 + 1), 0); Darwin.close(fd)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        for file in [source, link] {
            do { _ = try await service.prepare(scope: teamsTestScope, files: [file]); XCTFail("Unsafe source admitted") }
            catch let failure as TeamsFailure { XCTAssertEqual(failure, .invalidResource) }
        }
        XCTAssertEqual(try db.execute("SELECT count(*) FROM \"\(db.configuration.schema)\".teams_prepared_files")[0][0], "0")
        await repository.close()
    }
    func testS3OffUsesLocalAndNeverPromotesAfterEnable() async throws {
        let (db, repository, root, _) = try await fixture()
        let unavailable = try S3ObjectStoreConfiguration(endpoint: "http://127.0.0.1:9", region: "us-east-1", bucket: "synthetic-bucket", accessKeyID: "synthetic", secretAccessKey: "synthetic")
        let spool = root.appendingPathComponent("queue")
        let service = TeamsFiles(configuration: db.configuration, repository: repository, storage: unavailable, spoolDirectory: spool, keyProvider: teamsTestKey)
        try await service.setSavingFiles(scope: teamsTestScope, enabled: false)
        let file = root.appendingPathComponent("local.txt"), bytes = Data("private local preparation".utf8)
        try bytes.write(to: file)
        let prepared = try await service.prepare(scope: teamsTestScope, files: [file])
        XCTAssertEqual(prepared.first?.archiveReceipt?.state, .local)
        try await service.setSavingFiles(scope: teamsTestScope, enabled: true)
        let reopened = TeamsFiles(configuration: db.configuration, repository: repository, storage: unavailable, spoolDirectory: spool, keyProvider: teamsTestKey)
        let restored = try await reopened.prepared(scope: teamsTestScope, ids: prepared.map(\.id))
        XCTAssertEqual(restored.first?.archiveReceipt?.state, .local)
        let lease = try await reopened.openPrepared(scope: teamsTestScope, id: try XCTUnwrap(restored.first?.id))
        XCTAssertEqual(try Data(contentsOf: lease.url), bytes)
        await lease.release()
        await repository.close()
    }

    func testCancelledReleaseStillRemovesOwnedPlaintextLease() async throws {
        let (db, repository, root, storage) = try await fixture()
        let service = TeamsFiles(configuration: db.configuration, repository: repository, storage: storage, spoolDirectory: root.appendingPathComponent("queue"), keyProvider: teamsTestKey)
        try await service.setSavingFiles(scope: teamsTestScope, enabled: false)
        let file = root.appendingPathComponent("local.txt")
        try Data("owned temporary plaintext".utf8).write(to: file)
        let prepared = try await service.prepare(scope: teamsTestScope, files: [file])
        let lease = try await service.openPrepared(scope: teamsTestScope, id: try XCTUnwrap(prepared.first?.id))
        let releasing = Task { withUnsafeCurrentTask { $0?.cancel() }; await lease.release() }
        await releasing.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
        await repository.close()
    }
}

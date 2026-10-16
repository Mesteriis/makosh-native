import XCTest
import MakoshCore
@testable import MakoshApp
@testable import MakoshTeams

final class TeamsSyntheticIsolationTests: XCTestCase {
    func testSyntheticWorkerRejectsProductionSchemasBeforeDatabaseOrKeys() async throws {
        let worker = TeamsWorker.synthetic()
        do { _ = try await worker.load(configuration: .init(connectionString: "postgresql://127.0.0.1:9/never", schema: "qa_teams_app", archiveSchema: "makosh")); XCTFail("Production archive admitted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .invalidConfiguration) }
        await worker.shutdown()
        let db = try TeamsTestDatabase(); defer { try? db.cleanup() }
        let synthetic = TeamsWorker.synthetic()
        let accounts = try await synthetic.load(configuration: db.configuration)
        XCTAssertEqual(accounts.count, 2)
        try await synthetic.connect(accountID: accounts[0].id)
        let snapshot = try await synthetic.snapshot(accountID: accounts[0].id)
        XCTAssertEqual(snapshot.state, .synthetic)
        XCTAssertFalse(snapshot.chats.isEmpty)
        await synthetic.shutdown()
    }
    func testSyntheticFileSubmissionUsesOnlyPreparedLocalBytesAndFakeGraph() async throws {
        let db = try TeamsTestDatabase(); defer { try? db.cleanup() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: root) }
        let worker = TeamsWorker.synthetic(fileRoot: root)
        let account = try await worker.load(configuration: db.configuration)[0]
        try await worker.connect(accountID: account.id)
        let snapshot = try await worker.snapshot(accountID: account.id), scope = try XCTUnwrap(snapshot.chats.first?.scope)
        let storage = try S3ObjectStoreConfiguration(endpoint: "http://127.0.0.1:9", region: "us-east-1", bucket: "synthetic-bucket", accessKeyID: "synthetic", secretAccessKey: "synthetic")
        try await worker.configureFiles(storage: storage, spoolDirectory: root.appendingPathComponent("queue")); try await worker.setSavingFiles(scope: scope, enabled: false)
        let source = root.appendingPathComponent("пример.txt"); try Data("file".utf8).write(to: source)
        let files = try await worker.prepareFiles(scope: scope, files: [source])
        let plan = try await worker.fileAccessPlan(scope: scope, fileIDs: files.map(\.id), destination: .ownDrive(folderID: "qa-root"))
        let outgoing = try await worker.sendFiles(scope: scope, content: TeamsDraft(text: "Synthetic file", fileIDs: files.map(\.id)), accessPlan: plan)
        XCTAssertEqual(outgoing.state, .accepted)
        await worker.shutdown()
    }
    func testSyntheticWorkerRejectsUnselectedFileRootAndRemoteServices() async throws {
        XCTAssertFalse(TeamsQAIsolation.admitsDatabase(.init(connectionString: "postgresql://synthetic@example.invalid/db", schema: "qa_teams_app", archiveSchema: "qa_teams_archive")))
        XCTAssertFalse(TeamsQAIsolation.localEndpoint("https://s3.example.invalid"))
        let db = try TeamsTestDatabase(); defer { try? db.cleanup() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("fixtures"); try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: false)
        let other = root.appendingPathComponent("outside.txt"); try Data("owned test canary".utf8).write(to: other)
        let worker = TeamsWorker.synthetic(fileRoot: allowed)
        let account = try await worker.load(configuration: db.configuration)[0]
        let snapshot = try await worker.snapshot(accountID: account.id), scope = try XCTUnwrap(snapshot.chats.first?.scope)
        do { _ = try await worker.prepareFiles(scope: scope, files: [other]); XCTFail("Outside fixture read admitted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .invalidResource) }
        await worker.shutdown()
    }
    func testSyntheticOutboxExercisesPreparedAndUnknownWithoutDispatch() async throws {
        let db = try TeamsTestDatabase(); defer { try? db.cleanup() }
        let worker = TeamsWorker.synthetic()
        let account = try await worker.load(configuration: db.configuration)[0]
        let page = try await worker.outgoingPage(accountID: account.id, before: nil)
        XCTAssertTrue(page.values.contains { $0.state == .prepared })
        XCTAssertTrue(page.values.contains { $0.state == .unknown })
        await worker.shutdown()
    }
    func testSyntheticPreviewRequiresBothQASchemasAndNeverTouchesOtherServices() throws {
        let args = ["Makosh", "--teams-synthetic-preview", "--database-config", "/synthetic.json"]
        XCTAssertTrue(TeamsSyntheticLaunchPolicy.admits(arguments: args, configuration: .init(connectionString: "postgresql://synthetic@127.0.0.1/test?hostaddr=127.0.0.1", schema: "qa_teams_app", archiveSchema: "qa_teams_archive")))
        for config in [ContactWorkspaceConfiguration(connectionString: "postgresql://synthetic@127.0.0.1/test?hostaddr=127.0.0.1", schema: "makosh", archiveSchema: "qa_teams_archive"), .init(connectionString: "postgresql://synthetic@127.0.0.1/test?hostaddr=127.0.0.1", schema: "qa_teams_app", archiveSchema: "makosh")] {
            XCTAssertFalse(TeamsSyntheticLaunchPolicy.admits(arguments: args, configuration: config))
        }
        XCTAssertFalse(TeamsSyntheticLaunchPolicy.admits(arguments: ["Makosh", "--teams-synthetic-preview"], configuration: .init(connectionString: "postgresql://synthetic@127.0.0.1/test?hostaddr=127.0.0.1", schema: "qa_teams_app", archiveSchema: "qa_teams_archive")))
        let boundaries = TeamsSyntheticLaunchPolicy.serviceModes
        XCTAssertTrue(boundaries.telegramSynthetic && boundaries.mailSynthetic && boundaries.whatsappSynthetic)
        XCTAssertFalse(boundaries.startOtherWorkers)
    }
}

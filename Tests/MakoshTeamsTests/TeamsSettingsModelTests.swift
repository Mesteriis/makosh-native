import XCTest
import MakoshCore
@testable import MakoshApp
@testable import MakoshTeams

@MainActor final class TeamsSettingsModelTests: XCTestCase {
    func testSettingsSaveWaitsForRulesAndFilePolicy() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let base = TeamsWorker(repository: repository, transport: TeamsScriptedHTTP([]), vault: TeamsTokenVault(api: TeamsFakeKeychain()), automaticSync: false)
        _ = try await base.load(configuration: db.configuration)
        let storage = try S3ObjectStoreConfiguration(endpoint: "http://127.0.0.1:9", region: "us-east-1", bucket: "synthetic-bucket", accessKeyID: "synthetic", secretAccessKey: "synthetic")
        try await base.configureFiles(storage: storage, spoolDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let worker = TeamsModelFixture(base: base)
        let model = TeamsConversationPreferencesModel(worker: worker)
        model.reset(teamsTestScope)
        await worker.holdFilePolicy()
        let loading = Task { await model.load(expectedScope: teamsTestScope) }
        await worker.waitForHeld()
        XCTAssertTrue(model.rulesLoaded); XCTAssertFalse(model.canSave)
        let other = TeamsScope(accountID: teamsTestScope.accountID, tenantID: teamsTestScope.tenantID, resource: .chat("other"))
        model.reset(other)
        await worker.releaseHeld(); await loading.value
        XCTAssertFalse(model.canSave)
        await model.load(expectedScope: other)
        XCTAssertTrue(model.canSave)
        model.rule.preview = false; model.savingFiles = true
        await model.save(expectedScope: other)
        let saved = try await worker.savedNotificationRule(scope: .conversation(other))
        XCTAssertFalse(saved.preview)
        let saving = try await worker.savingFiles(scope: other); XCTAssertTrue(saving)
        await worker.shutdown()
    }
}

import XCTest
import MakoshCore
@testable import MakoshApp
@testable import MakoshTeams

@MainActor final class TeamsWorkspaceModelTests: XCTestCase {
    func fixture(postResponses: [TeamsHTTPResponse] = []) async throws -> (TeamsTestDatabase, TeamsModelFixture, TeamsScope) {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let otherID = UUID()
        let other = TeamsScope(accountID: otherID, tenantID: teamsTestScope.tenantID, resource: .chat("other"))
        let old = try await repository.accounts()[0]
        try await repository.saveAccount(TeamsAccount(id: otherID, name: "Second", clientID: old.clientID, authority: old.authority, verifiedPrincipal: teamsTestContext.principal, readOnly: false))
        for scope in [teamsTestScope, other] {
            let context = TeamsAccountContext(accountID: scope.accountID, principal: teamsTestContext.principal)
            try await repository.saveConversations([TeamsConversation(scope: scope, displayName: "Test", kind: .oneOnOne)], collection: TeamsCollection(context: context, kind: .chats), next: nil, failure: nil)
            _ = try await repository.commit(page: TeamsPage(values: [TeamsMessage(id: "cached", scope: scope, body: "Cached <literal>", contentType: "text", author: nil, createdAt: Date(), modifiedAt: nil, deletedAt: nil, attachments: [], replyTo: nil)], next: nil, continuationFailure: nil), collection: TeamsCollection(context: context, kind: .messages(scope.resource)), baseline: true)
        }
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        for id in [teamsTestScope.accountID, otherID] {
            try await vault.save(TeamsTokenBundle(accessToken: "synthetic", refreshToken: nil, idToken: nil, expiresAt: Date().addingTimeInterval(3600), grantedScopes: ["User.Read", "Chat.Read", "ChatMessage.Send"], expectedNonce: nil), accountID: id)
        }
        let http = TeamsRoutedHTTP(["/v1.0/chats/test-chat/messages": postResponses, "/v1.0/me": [teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Test\"}")],
            "/11111111-1111-4111-8111-111111111111/oauth2/v2.0/devicecode": [teamsJSON("{\"device_code\":\"synthetic\",\"user_code\":\"TEST-CODE\",\"verification_uri\":\"https://microsoft.com/devicelogin\",\"expires_in\":300,\"interval\":5}")]])
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: false)
        return (db, TeamsModelFixture(base: worker), other)
    }
    func testDefinitiveRejectedSendKeepsDraftAndNeverClaimsAcceptance() async throws {
        let (db, worker, _) = try await fixture(postResponses: [teamsJSON("{}", status: 403)])
        let model = TeamsWorkspaceModel(worker: worker, polling: false)
        await model.load(configuration: db.configuration); await model.selectAccount(teamsTestScope.accountID); await model.connect(); await model.selectConversation(teamsTestScope)
        model.composer.text = "Keep rejected draft"
        await model.composer.send()
        XCTAssertEqual(model.composer.outbox.first?.state, .notSent)
        XCTAssertEqual(model.composer.text, "Keep rejected draft")
        XCTAssertTrue(model.composer.notice?.contains("Не отправлено") == true)
        XCTAssertFalse(model.composer.notice?.contains("принято") == true)
        await model.shutdown()
    }
    func testLateAcceptedSendClearsOnlyOriginalUnchangedDraft() async throws {
        let (db, worker, other) = try await fixture()
        let transport = await worker.base.transport
        let http = try XCTUnwrap(transport as? TeamsRoutedHTTP)
        await http.hold("/v1.0/chats/test-chat/messages")
        let model = TeamsWorkspaceModel(worker: worker, polling: false)
        await model.load(configuration: db.configuration); await model.selectAccount(teamsTestScope.accountID); await model.connect(); await model.selectConversation(teamsTestScope)
        model.composer.text = "Captured draft"
        let sending = Task { await model.composer.send() }
        await http.waitForHeldRequest()
        await model.selectAccount(other.accountID); await model.selectConversation(other)
        model.composer.text = "Other draft"
        await http.release(teamsJSON("{\"id\":\"accepted-late\",\"body\":{\"contentType\":\"text\",\"content\":\"Captured draft\"}}", status: 201))
        await sending.value
        XCTAssertEqual(model.composer.text, "Other draft")
        await model.selectAccount(teamsTestScope.accountID); await model.selectConversation(teamsTestScope)
        XCTAssertEqual(model.composer.text, "")
        await model.shutdown()
    }
    func testLateAcceptedSendPreservesInterveningOriginalEdit() async throws {
        let (db, worker, other) = try await fixture()
        let transport = await worker.base.transport
        let http = try XCTUnwrap(transport as? TeamsRoutedHTTP)
        await http.hold("/v1.0/chats/test-chat/messages")
        let model = TeamsWorkspaceModel(worker: worker, polling: false)
        await model.load(configuration: db.configuration); await model.selectAccount(teamsTestScope.accountID); await model.connect(); await model.selectConversation(teamsTestScope)
        model.composer.text = "Captured draft"
        let sending = Task { await model.composer.send() }
        await http.waitForHeldRequest()
        await model.selectAccount(other.accountID); await model.selectConversation(other)
        model.composer.text = "Other draft"
        await model.selectAccount(teamsTestScope.accountID); await model.selectConversation(teamsTestScope)
        model.composer.text = "Edited during submission"
        await model.selectAccount(other.accountID); await model.selectConversation(other)
        await http.release(teamsJSON("{\"id\":\"accepted-late\",\"body\":{\"contentType\":\"text\",\"content\":\"Captured draft\"}}", status: 201))
        await sending.value
        XCTAssertEqual(model.composer.text, "Other draft")
        await model.selectAccount(teamsTestScope.accountID); await model.selectConversation(teamsTestScope)
        XCTAssertEqual(model.composer.text, "Edited during submission")
        await model.shutdown()
    }
    func testRefreshDoesNotDiscardLoadedHistoryPages() async throws {
        let (db, worker, _) = try await fixture()
        let repository = await worker.base.repository
        let values = (1...65).map { index in TeamsMessage(id: "page-\(index)", scope: teamsTestScope, body: "History \(index)", contentType: "text", author: nil, createdAt: Date(), modifiedAt: nil, deletedAt: nil, attachments: [], replyTo: nil) }
        _ = try await repository.commit(page: TeamsPage(values: values, next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: true)
        let model = TeamsWorkspaceModel(worker: worker, polling: false)
        await model.load(configuration: db.configuration); await model.selectAccount(teamsTestScope.accountID); await model.selectConversation(teamsTestScope)
        await model.loadHistory(reset: false)
        XCTAssertEqual(model.messages.count, 66)
        await model.refresh()
        XCTAssertEqual(model.messages.count, 66, "Polling must preserve the chosen history snapshot")
        await model.shutdown()
    }
    func testArchivePresentationKeepsLiteralPlainAngles() async throws {
        let (db, worker, _) = try await fixture()
        _ = try await worker.load(configuration: db.configuration)
        let model = TeamsHistoryModel(worker: worker, scope: teamsTestScope)
        await model.load()
        XCTAssertEqual(model.rows.first?.text, "Cached <literal>")
        await worker.shutdown()
    }
    func testLateHistoryAndComposerCannotFollowNewSelection() async throws {
        let (db, worker, other) = try await fixture()
        let model = TeamsWorkspaceModel(worker: worker, polling: false)
        await model.load(configuration: db.configuration)
        await model.selectAccount(teamsTestScope.accountID)
        await worker.holdHistory()
        let selecting = Task { await model.selectConversation(teamsTestScope) }
        await worker.waitForHeld()
        model.composer.text = "First draft"
        await model.selectAccount(other.accountID)
        await model.selectConversation(other)
        model.composer.text = "Second draft"
        await worker.releaseHeld(); await selecting.value
        XCTAssertEqual(model.selectedAccountID, other.accountID)
        XCTAssertEqual(model.selectedScope, other)
        XCTAssertEqual(model.messages.first?.scope, other)
        XCTAssertEqual(model.composer.text, "Second draft")
        await model.selectAccount(teamsTestScope.accountID)
        await model.selectConversation(teamsTestScope)
        XCTAssertEqual(model.composer.text, "First draft")
        await model.shutdown()
    }
    func testLatePreparationStaysInOriginalDraft() async throws {
        let (db, worker, other) = try await fixture()
        let model = TeamsWorkspaceModel(worker: worker, polling: false)
        await model.load(configuration: db.configuration)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let storage = try S3ObjectStoreConfiguration(endpoint: "http://127.0.0.1:9", region: "us-east-1", bucket: "synthetic-bucket", accessKeyID: "synthetic", secretAccessKey: "synthetic")
        try await worker.configureFiles(storage: storage, spoolDirectory: root.appendingPathComponent("queue"))
        try await worker.setSavingFiles(scope: teamsTestScope, enabled: false)
        await model.selectAccount(teamsTestScope.accountID); await model.selectConversation(teamsTestScope)
        let source = root.appendingPathComponent("file.txt"); try Data("file".utf8).write(to: source)
        await worker.holdPreparation()
        let preparing = Task { await model.composer.attach([source]) }
        await worker.waitForHeld()
        await model.selectAccount(other.accountID); await model.selectConversation(other)
        await worker.releaseHeld(); await preparing.value
        XCTAssertTrue(model.composer.attachments.isEmpty)
        await model.selectAccount(teamsTestScope.accountID); await model.selectConversation(teamsTestScope)
        XCTAssertEqual(model.composer.attachments.count, 1)
        await model.shutdown()
    }
    func testCancelIncrementalConsentKeepsCurrentAccount() async throws {
        let (db, worker, _) = try await fixture()
        let model = TeamsWorkspaceModel(worker: worker, polling: false)
        await model.load(configuration: db.configuration)
        await model.selectAccount(teamsTestScope.accountID)
        await model.connect()
        XCTAssertEqual(model.snapshot?.state, .connected)
        await model.authorize(method: .deviceCode, capabilities: [.basicChats, .readFiles])
        await model.cancelAuthorization()
        XCTAssertEqual(model.selectedAccountID, teamsTestScope.accountID)
        XCTAssertEqual(model.snapshot?.state, .connected)
        await model.shutdown()
    }
}

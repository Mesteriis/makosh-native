import XCTest
import MakoshCore
@testable import MakoshTeams

@MainActor
final class TeamsFileDownloadTests: XCTestCase {
    func testHostedReferencesAreScopedAndNeverDecodeBytesIntoJournal() throws {
        let body = "<img src=\"https://graph.microsoft.com/v1.0/chats/test-chat/messages/hosted/hostedContents/image-id/$value\"><img src=\"https://evil.invalid/hostedContents/not-owned/$value\">"
        let payload = try JSONSerialization.data(withJSONObject: ["id": "hosted", "body": ["contentType": "html", "content": body], "hostedContents": [["id": "ignored", "contentBytes": "PRIVATE_BYTES"]]])
        let wire = try JSONDecoder().decode(TeamsGraphMessage.self, from: payload)
        let message = try wire.message(scope: teamsTestScope)
        XCTAssertEqual(message.attachments.map(\.id), ["image-id"])
        XCTAssertEqual(message.attachments.first?.contentType, "makosh/teams-hosted")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(message), as: UTF8.self).contains("PRIVATE_BYTES"))
    }
    func testCaptureContentionStopsDrainAndLeavesPendingForNextPoll() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        try await repository.saveConversations([TeamsConversation(scope: teamsTestScope, displayName: "Personal", kind: .oneOnOne)], collection: TeamsCollection(context: teamsTestContext, kind: .chats), next: nil, failure: nil)
        let attachment = TeamsAttachment(id: "file", name: "file.txt", contentType: "reference", contentURL: URL(string: "https://test.sharepoint.com/file.txt"))
        let message = TeamsMessage(id: "incoming", scope: teamsTestScope, body: "file", contentType: "text", author: nil, createdAt: Date(), modifiedAt: nil, deletedAt: nil, attachments: [attachment], replyTo: nil, metadata: [:])
        _ = try await repository.commit(page: TeamsPage(values: [message], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        let jobs = try await repository.incomingFiles(scope: teamsTestScope, pendingOnly: true)
        XCTAssertEqual(jobs.count, 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let storage = try S3ConfigurationFile.read(URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let files = TeamsFiles(configuration: db.configuration, repository: repository, storage: storage, spoolDirectory: root.appendingPathComponent("spool"), keyProvider: teamsTestKey)
        let owner = TeamsRepository(keyProvider: teamsTestKey); try await owner.open(configuration: db.configuration)
        let held = try await owner.acquireLease(kind: .sync, accountID: teamsTestScope.accountID, operationID: UUID())
        let budget = TeamsCaptureBudget()
        do {
            try await files.capturePending(accountID: teamsTestScope.accountID, graph: TeamsGraphFiles(context: teamsTestContext, transport: TeamsScriptedHTTP([])), token: "synthetic", capabilities: [.resolveSharedLink, .readFiles], downloader: TeamsTestFileDownloader(), authorize: { try await budget.check() })
            XCTFail("Contention should propagate to scheduled polling")
        } catch let failure as TeamsFailure { XCTAssertEqual(failure, .operationBusy) }
        let checks = await budget.calls; XCTAssertLessThanOrEqual(checks, 2)
        let pending = try await repository.incomingFiles(scope: teamsTestScope, pendingOnly: true)
        XCTAssertEqual(pending.count, 1)
        try await owner.releaseLease(held); await owner.close(); await repository.close()
    }
    func testIncomingReservationSurvivesReopenAndStoredFileReadsWithS3Off() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        try await repository.saveConversations([TeamsConversation(scope: teamsTestScope, displayName: "Personal", kind: .oneOnOne)], collection: TeamsCollection(context: teamsTestContext, kind: .chats), next: nil, failure: nil)
        let attachment = TeamsAttachment(id: "file", name: "file.txt", contentType: "reference", contentURL: URL(string: "https://test.sharepoint.com/file.txt"))
        let message = TeamsMessage(id: "incoming", scope: teamsTestScope, body: "file", contentType: "text", author: nil, createdAt: Date(), modifiedAt: nil, deletedAt: nil, attachments: [attachment], replyTo: nil, metadata: [:])
        _ = try await repository.commit(page: TeamsPage(values: [message], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        let jobs = try await repository.incomingFiles(scope: teamsTestScope, pendingOnly: true)
        XCTAssertEqual(jobs.count, 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let storage = try S3ConfigurationFile.read(URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let files = TeamsFiles(configuration: db.configuration, repository: repository, storage: storage, spoolDirectory: root.appendingPathComponent("spool"), keyProvider: teamsTestKey)
        let body = "{\"id\":\"item\",\"name\":\"file.txt\",\"size\":4,\"eTag\":\"etag\",\"file\":{},\"parentReference\":{\"driveId\":\"drive\"}}"
        let graph = TeamsGraphFiles(context: teamsTestContext, transport: TeamsScriptedHTTP([teamsJSON(body), teamsJSON(body), teamsJSON(body)]))
        let held = try await repository.acquireLease(kind: .sync, accountID: teamsTestScope.accountID, operationID: UUID())
        do { _ = try await files.download(job: jobs[0], graph: TeamsGraphFiles(context: teamsTestContext, transport: TeamsScriptedHTTP([])), token: "synthetic", capabilities: [.resolveSharedLink, .readFiles], downloader: TeamsTestFileDownloader()); XCTFail("Live file owner ignored") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .operationBusy) }
        try await repository.releaseLease(held)
        let lease = try await files.download(job: jobs[0], graph: graph, token: "synthetic", capabilities: [.resolveSharedLink, .readFiles], downloader: TeamsTestFileDownloader())
        await lease.release()
        try await files.setSavingFiles(scope: teamsTestScope, enabled: false)
        let stored = try await repository.incomingFiles(scope: teamsTestScope, pendingOnly: false)
        XCTAssertEqual(stored[0].id, jobs[0].id)
        XCTAssertEqual(stored[0].receipt?.state, .stored)
        let reopened = TeamsFiles(configuration: db.configuration, repository: repository, storage: storage, spoolDirectory: root.appendingPathComponent("spool"), keyProvider: teamsTestKey)
        let offline = try await reopened.download(job: stored[0], graph: TeamsGraphFiles(context: teamsTestContext, transport: TeamsScriptedHTTP([])), token: "unused", capabilities: [], downloader: TeamsTestFileDownloader())
        XCTAssertEqual(try Data(contentsOf: offline.url), Data("file".utf8))
        await offline.release(); await repository.close()
    }
    func testDownloadRedirectNeverCarriesBearerOrCookies() async throws {
        let http = TeamsScriptedHTTP([teamsJSON("{\"id\":\"item\",\"name\":\"file.txt\",\"size\":4,\"eTag\":\"etag\",\"file\":{},\"parentReference\":{\"driveId\":\"drive\"}}"), teamsJSON("{\"id\":\"item\",\"name\":\"file.txt\",\"size\":4,\"eTag\":\"etag\",\"file\":{},\"parentReference\":{\"driveId\":\"drive\"}}")])
        let graph = TeamsGraphFiles(context: teamsTestContext, transport: http)
        let remote = TeamsRemoteFile(driveID: "drive", itemID: "item", versionID: nil, eTag: "etag", name: "file.txt", size: 4, webURL: nil)
        let downloader = TeamsTestFileDownloader()
        let lease = try await graph.download(remote, token: "synthetic", capabilities: [.readFiles], downloader: downloader)
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("file".utf8))
        let requests = await downloader.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
        await lease.release()
    }
    func testSharingURLLookupRequiresExplicitWriteScopeAndNeverRedeems() async throws {
        let http = TeamsScriptedHTTP([teamsJSON("{\"id\":\"item\",\"name\":\"test.txt\",\"size\":4,\"eTag\":\"etag1\",\"file\":{\"mimeType\":\"text/plain\"},\"webUrl\":\"https://test.sharepoint.com/test.txt\",\"parentReference\":{\"driveId\":\"drive\"}}")])
        let graph = TeamsGraphFiles(context: teamsTestContext, transport: http)
        let url = URL(string: "https://test.sharepoint.com/shared/test.txt")!
        do { _ = try await graph.resolveSharedURL(url, token: "synthetic", capabilities: [.readFiles]); XCTFail("Write consent bypassed") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .forbidden) }
        let before = await http.requests
        XCTAssertTrue(before.isEmpty)
        let item = try await graph.resolveSharedURL(url, token: "synthetic", capabilities: [.resolveSharedLink])
        XCTAssertEqual(item.itemID, "item"); XCTAssertEqual(item.driveID, "drive")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Prefer"))
        XCTAssertTrue(requests.first?.url?.path.hasPrefix("/v1.0/shares/u!") ?? false)
        XCTAssertEqual(requests.first?.url?.host, "graph.microsoft.com")
    }

    func testLongSharingURLIsEncodedWithoutTruncation() async throws {
        let http = TeamsScriptedHTTP([teamsJSON("{\"id\":\"item\",\"name\":\"test.txt\",\"size\":4,\"file\":{},\"parentReference\":{\"driveId\":\"drive\"}}")])
        let url = URL(string: "https://test.sharepoint.com/shared?opaque=" + String(repeating: "x", count: 1500))!
        _ = try await TeamsGraphFiles(context: teamsTestContext, transport: http).resolveSharedURL(url, token: "synthetic", capabilities: [.resolveSharedLink])
        let requests = await http.requests
        XCTAssertTrue(requests.first?.url?.path.contains(Data(url.absoluteString.utf8).teamsBase64URL) == true)
    }
    func testHistoricalResourceDoesNotDownloadReplacement() async throws {
        let http = TeamsScriptedHTTP([teamsJSON("{\"id\":\"item\",\"name\":\"replacement.txt\",\"size\":8,\"eTag\":\"new-etag\",\"file\":{\"mimeType\":\"text/plain\"},\"parentReference\":{\"driveId\":\"drive\"}}")])
        let graph = TeamsGraphFiles(context: teamsTestContext, transport: http)
        let original = TeamsRemoteFile(driveID: "drive", itemID: "item", versionID: nil, eTag: "original-etag", name: "original.txt", size: 4, webURL: nil)
        do { _ = try await graph.currentContentRequest(original, token: "synthetic", capabilities: [.readFiles]); XCTFail("Replacement substituted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .historicalFileUnavailable) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/content") == true })
    }
}

actor TeamsTestFileDownloader: TeamsFileDownloading {
    private(set) var requests: [URLRequest] = []
    func download(_ request: URLRequest, to destination: URL, maximumBytes: Int64) async throws -> TeamsFileDownloadResponse {
        requests.append(request)
        if request.url?.host == "graph.microsoft.com" { return TeamsFileDownloadResponse(status: 302, headers: ["Location": "https://download.sharepoint.com/synthetic?private-token=transient"], byteCount: 0) }
        try Data("file".utf8).write(to: destination)
        return TeamsFileDownloadResponse(status: 200, headers: [:], byteCount: 4)
    }
}

private actor TeamsCaptureBudget {
    private(set) var calls = 0
    func check() throws { calls += 1; if calls >= 4 { throw TeamsFailure.invalidResource } }
}

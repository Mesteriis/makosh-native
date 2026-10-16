import XCTest
import MakoshCore
@testable import MakoshTeams

@MainActor
final class TeamsFileSubmissionTests: XCTestCase {
    func testFolderRejectsInheritedWriteForReviewedRecipient() async throws {
        let peer = "88888888-8888-4888-8888-888888888888"
        let http = TeamsScriptedHTTP([teamsJSON("{\"id\":\"drive\",\"owner\":{\"user\":{\"id\":\"\(teamsTestContext.principal.userID)\"}}}"), teamsJSON("{\"id\":\"folder\",\"name\":\"Selected\",\"folder\":{},\"parentReference\":{\"driveId\":\"drive\"}}"), teamsJSON("{\"value\":[{\"roles\":[\"write\"],\"grantedToV2\":{\"user\":{\"id\":\"\(peer)\"}}}]}")])
        let roster = TeamsFileRoster(scope: teamsTestScope, recipients: [.init(userID: peer, tenantID: teamsTestScope.tenantID, displayName: "Peer", email: nil)], membershipDigest: "captured")
        do { _ = try await TeamsGraphFiles(context: teamsTestContext, transport: http).folder(destination: .ownDrive(folderID: "folder"), roster: roster, token: "synthetic", capabilities: [.writeFiles]); XCTFail("Inherited write is broader than reviewed read access") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .incompleteGrant) }
    }
    func testFolderPickerPaginatesWithoutAcceptingForeignContinuation() async throws {
        let root = "/v1.0/me/drive/root/children"
        let http = TeamsRoutedHTTP(["/v1.0/me/drive/root": [teamsJSON("{\"id\":\"root-id\",\"name\":\"OneDrive\",\"folder\":{}}"), teamsJSON("{\"id\":\"root-id\",\"name\":\"OneDrive\",\"folder\":{}}")], root: [teamsJSON("{\"value\":[{\"id\":\"folder-one\",\"name\":\"Documents\",\"folder\":{}}],\"@odata.nextLink\":\"https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=second\"}")], root + "?$skiptoken=second": [teamsJSON("{\"value\":[{\"id\":\"folder-two\",\"name\":\"More\",\"folder\":{}}]}")]])
        let graph = TeamsGraphFiles(context: teamsTestContext, transport: http)
        let first = try await graph.folders(parentID: nil, continuation: nil, token: "synthetic", capabilities: [.writeFiles])
        XCTAssertEqual(first.values.map(\.name), ["Documents"])
        XCTAssertEqual(first.parent.id, "root-id")
        let second = try await graph.folders(parentID: nil, continuation: first.next, token: "synthetic", capabilities: [.writeFiles])
        XCTAssertEqual(second.values.map(\.name), ["More"]); XCTAssertNil(second.next)
    }
    func testUploadIsStreamingNonOverwritingAndUnknownIsNotRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source")
        try Data("file".utf8).write(to: file)
        let prepared = TeamsPreparedFile(id: UUID(), scope: teamsTestScope, name: "document.txt", size: 4,
            sha256: "3b9c358f36f0a31b6ad3e14f309c7cf198ac9246e8316f9ce543d5b19ac02b80", archiveReceipt: nil)
        let http = TeamsFileUploadHTTP()
        let graph = TeamsGraphFiles(context: teamsTestContext, transport: http)
        let folder = TeamsFileFolder(driveID: "drive", itemID: "folder", name: "Selected", ownerVerified: true)
        let remote = try await graph.upload(prepared, from: file, folder: folder, targetID: UUID(), token: "synthetic", capabilities: [.writeFiles])
        XCTAssertEqual(remote.size, 4)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "PUT")
        let query = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "@microsoft.graph.conflictBehavior", value: "fail")])
        let bodies = await http.files
        XCTAssertEqual(bodies, [Data("file".utf8)])
        await http.makeUnknown()
        do { _ = try await graph.upload(prepared, from: file, folder: folder, targetID: UUID(), token: "synthetic", capabilities: [.writeFiles]); XCTFail("Unknown upload accepted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .uncertainSubmission) }
        let after = await http.requests
        XCTAssertEqual(after.count, 2)
    }
    func testChannelInheritedReadRequiresExactParentAndCompleteAudience() async throws {
        let scope = TeamsScope(accountID: teamsTestScope.accountID, tenantID: teamsTestScope.tenantID, resource: .channel(teamID: "team", channelID: "channel"))
        let peer = TeamsFileRecipient(userID: "88888888-8888-4888-8888-888888888888", tenantID: teamsTestScope.tenantID, displayName: "Peer", email: nil)
        let roster = TeamsFileRoster(scope: scope, recipients: [peer], membershipDigest: "captured")
        let file = TeamsRemoteFile(driveID: "drive", itemID: "uploaded", versionID: nil, eTag: "e", name: "file", size: 4, webURL: nil)
        for parent in ["folder", "other", ""] {
            let permissions: [[String: Any]] = [["roles": ["owner"], "grantedToV2": ["user": ["id": teamsTestContext.principal.userID]]]] + (parent.isEmpty ? [] : [["roles": ["read"], "inheritedFrom": ["driveId": "drive", "id": parent], "grantedToV2": ["user": ["id": peer.userID]]]])
            let response = TeamsHTTPResponse(status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: ["value": permissions]))
            let graph = TeamsGraphFiles(context: teamsTestContext, transport: TeamsScriptedHTTP([response]))
            do {
                try await graph.verifyInheritedRead(file, folder: TeamsFileFolder(driveID: "drive", itemID: "folder", name: "Channel", ownerVerified: true), roster: roster, token: "synthetic", capabilities: [.writeSharedFiles])
                XCTAssertEqual(parent, "folder")
            } catch let failure as TeamsFailure { XCTAssertNotEqual(parent, "folder"); XCTAssertEqual(failure, .incompleteGrant) }
        }
    }
    func testFolderWithBroadOrIncompletePermissionsIsRejected() async throws {
        for permissions in ["{\"value\":[{\"roles\":[\"read\"],\"link\":{\"scope\":\"organization\"}}]}", "{\"value\":[],\"@odata.nextLink\":\"https://evil.invalid\"}"] {
            let http = TeamsScriptedHTTP([teamsJSON("{\"id\":\"drive\",\"owner\":{\"user\":{\"id\":\"\(teamsTestContext.principal.userID)\"}}}"),
                teamsJSON("{\"id\":\"folder\",\"name\":\"Selected\",\"folder\":{},\"parentReference\":{\"driveId\":\"drive\"}}"), teamsJSON(permissions)])
            do { _ = try await TeamsGraphFiles(context: teamsTestContext, transport: http).folder(destination: .ownDrive(folderID: "folder"), roster: TeamsFileRoster(scope: teamsTestScope, recipients: [], membershipDigest: "captured"), token: "synthetic", capabilities: [.writeFiles]); XCTFail("Broad or incomplete folder admitted") }
            catch is TeamsFailure {}
        }
    }
    func testPartialGrantAndUnknownUploadNeverPublishOrReplay() async throws {
        for unknownUpload in [false, true] {
            let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
            let repository = try await teamsTestRepository(db)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            addTeardownBlock { try FileManager.default.removeItem(at: root) }
            let storage = try S3ObjectStoreConfiguration(endpoint: "http://127.0.0.1:9", region: "us-east-1", bucket: "synthetic-bucket", accessKeyID: "synthetic", secretAccessKey: "synthetic")
            let files = TeamsFiles(configuration: db.configuration, repository: repository, storage: storage, spoolDirectory: root.appendingPathComponent("spool"), keyProvider: teamsTestKey)
            let source = root.appendingPathComponent("one.txt"); try Data("file".utf8).write(to: source)
            let prepared = try await files.prepare(scope: teamsTestScope, files: [source])
            let http = TeamsFileUploadHTTP(); if unknownUpload { await http.makeUnknown() }
            let roster = try await TeamsGraphFiles(context: teamsTestContext, transport: http).roster(scope: teamsTestScope, token: "synthetic", capabilities: [.basicChats])
            let plan = TeamsFileAccessPlan(id: UUID(), scope: teamsTestScope, fileIDs: prepared.map(\.id), destination: .ownDrive(folderID: "folder"), folder: TeamsFileFolder(driveID: "drive", itemID: "folder", name: "Selected", ownerVerified: true), roster: roster)
            try await repository.saveFilePlan(plan)
            let outgoing = try await repository.prepareFileOutgoing(scope: teamsTestScope, content: TeamsDraft(text: "files", fileIDs: prepared.map(\.id)), planID: plan.id)
            let claimed = try await repository.claimOutgoing(id: outgoing.id, accountID: teamsTestScope.accountID)
            let pipeline = TeamsFileSubmission(repository: repository, files: files, graph: TeamsGraphFiles(context: teamsTestContext, transport: http))
            let result = try await pipeline.dispatch(claimed, token: "synthetic", capabilities: [.basicChats, .writeFiles], authorize: {})
            XCTAssertEqual(result.state, .unknown)
            do { _ = try await repository.claimOutgoing(id: result.id, accountID: result.scope.accountID); XCTFail("Unknown stage replayed") } catch is TeamsFailure {}
            do { _ = try await repository.prepareFileOutgoing(scope: teamsTestScope, content: outgoing.content, planID: plan.id); XCTFail("Consumed plan reused") } catch is TeamsFailure {}
            let journal = try await repository.outgoingPage(accountID: teamsTestScope.accountID, before: nil)
            XCTAssertEqual(journal.values.count, 1, "Rejected plan reuse must be atomic")
            let requests = await http.requests
            XCTAssertEqual(requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("messages") == true }.count, 0)
            XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("invite") == true }.count, unknownUpload ? 0 : 1)
            XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
            await repository.close()
        }
    }
    // A complete roster requires every page and an unambiguous tenant/user tuple, never the expanded chat hint.
    func testChangedOrIncompleteRosterStopsBeforeGrant() async throws {
        let route = "/v1.0/chats/test-chat/members"
        let http = TeamsRoutedHTTP([
            route: [teamsJSON("""
            {"value":[{"id":"opaque-self","userId":"22222222-2222-4222-8222-222222222222","tenantId":"11111111-1111-4111-8111-111111111111","displayName":"Me"}],
             "@odata.nextLink":"https://graph.microsoft.com/v1.0/chats/test-chat/members?$skiptoken=second"}
            """), teamsJSON("""
            {"value":[{"id":"opaque-self","userId":"22222222-2222-4222-8222-222222222222","tenantId":"11111111-1111-4111-8111-111111111111","displayName":"Me"},
                      {"id":"opaque-new","userId":"99999999-9999-4999-8999-999999999999","tenantId":"11111111-1111-4111-8111-111111111111","displayName":"New User"}]}
            """)],
            route + "?$skiptoken=second": [teamsJSON("{\"value\":[{\"id\":\"opaque-peer\",\"userId\":\"88888888-8888-4888-8888-888888888888\",\"tenantId\":\"11111111-1111-4111-8111-111111111111\",\"displayName\":\"Peer\"}]}")]
        ])
        let graph = TeamsGraphFiles(context: teamsTestContext, transport: http)
        let roster = try await graph.roster(scope: teamsTestScope, token: "synthetic", capabilities: [.basicChats])
        XCTAssertEqual(roster.recipients.map(\.displayName), ["Peer"])
        do { try await graph.recheckRoster(roster, scope: teamsTestScope, token: "synthetic", capabilities: [.basicChats]); XCTFail("Changed audience accepted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .rosterChanged) }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 0)
        let missing = TeamsScriptedHTTP([teamsJSON("{\"value\":[{\"id\":\"opaque\",\"userId\":\"88888888-8888-4888-8888-888888888888\",\"displayName\":\"Unknown tenant\"}]}")])
        do { _ = try await TeamsGraphFiles(context: teamsTestContext, transport: missing).roster(scope: teamsTestScope, token: "synthetic", capabilities: [.basicChats]); XCTFail("Incomplete identity accepted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .incompleteRoster) }
    }

    func testPartialGrantNeverAuthorizesPublication() async throws {
        let http = TeamsScriptedHTTP([teamsJSON("{\"value\":[{\"id\":\"permission\",\"roles\":[\"read\"],\"grantedToIdentitiesV2\":[{\"user\":{\"id\":\"88888888-8888-4888-8888-888888888888\"}}]},{\"error\":{\"code\":\"accessDenied\"}}]}", status: 207)])
        let graph = TeamsGraphFiles(context: teamsTestContext, transport: http)
        let remote = TeamsRemoteFile(driveID: "drive", itemID: "item", versionID: nil, eTag: "etag", name: "file.txt", size: 4, webURL: URL(string: "https://test.sharepoint.com/file.txt"))
        let recipients = [TeamsFileRecipient(userID: "88888888-8888-4888-8888-888888888888", tenantID: teamsTestContext.principal.tenantID, displayName: "Peer", email: nil),
                          TeamsFileRecipient(userID: "99999999-9999-4999-8999-999999999999", tenantID: teamsTestContext.principal.tenantID, displayName: "Second", email: nil)]
        do { try await graph.grantRead(remote, recipients: recipients, token: "synthetic", capabilities: [.writeFiles]); XCTFail("Partial grant accepted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .incompleteGrant) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(requests.first?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["roles"] as? [String], ["read"])
        XCTAssertEqual(body?["sendInvitation"] as? Bool, false)
        XCTAssertEqual(body?["requireSignIn"] as? Bool, true)
    }
}

actor TeamsFileUploadHTTP: TeamsHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var files: [Data] = []
    private var unknown = false
    private var completeGrant = false
    private var echoRepository: TeamsRepository?
    func echoInto(_ repository: TeamsRepository) { echoRepository = repository }
    private var channelMode = false
    func useChannel() { channelMode = true }
    func permitCompleteGrant() { completeGrant = true }
    func makeUnknown() { unknown = true }
    func response(to request: URLRequest) async throws -> TeamsHTTPResponse {
        requests.append(request)
        switch request.url!.path {
        case "/v1.0/me": return teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Self\"}")
        case "/v1.0/chats/test-chat/members", "/v1.0/teams/team/channels/channel/allMembers": return teamsJSON("{\"value\":[{\"id\":\"self\",\"userId\":\"\(teamsTestContext.principal.userID)\",\"tenantId\":\"\(teamsTestContext.principal.tenantID)\",\"displayName\":\"Self\"},{\"id\":\"peer\",\"userId\":\"88888888-8888-4888-8888-888888888888\",\"tenantId\":\"\(teamsTestContext.principal.tenantID)\",\"displayName\":\"Peer\"}]}")
        case "/v1.0/me/drive": return teamsJSON("{\"id\":\"drive\",\"owner\":{\"user\":{\"id\":\"\(teamsTestContext.principal.userID)\"}}}")
        case "/v1.0/drives/drive/items/folder", "/v1.0/teams/team/channels/channel/filesFolder": return teamsJSON("{\"id\":\"folder\",\"name\":\"Selected\",\"folder\":{},\"parentReference\":{\"driveId\":\"drive\"}}")
        case "/v1.0/drives/drive/items/folder/permissions", "/v1.0/drives/drive/items/uploaded/permissions":
            if channelMode { return teamsJSON("{\"value\":[{\"roles\":[\"owner\"],\"grantedToV2\":{\"user\":{\"id\":\"\(teamsTestContext.principal.userID)\"}}},{\"roles\":[\"read\"],\"inheritedFrom\":{\"driveId\":\"drive\",\"id\":\"folder\"},\"grantedToV2\":{\"user\":{\"id\":\"88888888-8888-4888-8888-888888888888\"}}}]}") }
            return teamsJSON("{\"value\":[]}")
        case "/v1.0/drives/drive/items/uploaded/invite":
            if completeGrant { return teamsJSON("{\"value\":[{\"roles\":[\"read\"],\"grantedToV2\":{\"user\":{\"id\":\"88888888-8888-4888-8888-888888888888\"}}}]}") }
            return teamsJSON("{\"value\":[]}", status: 207)
        case "/v1.0/chats/test-chat/messages", "/v1.0/teams/team/channels/channel/messages":
            var body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            body["id"] = "accepted-file"
            let data = try JSONSerialization.data(withJSONObject: body)
            if let echoRepository {
                let message = try JSONDecoder().decode(TeamsGraphMessage.self, from: data).message(scope: teamsTestScope)
                _ = try await echoRepository.commit(page: TeamsPage(values: [message], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
            }
            return TeamsHTTPResponse(status: 201, headers: [:], body: data)
        default: throw TeamsFailure.transport
        }
    }
    func upload(file: URL, to request: URLRequest) async throws -> TeamsHTTPResponse {
        requests.append(request); files.append(try Data(contentsOf: file))
        if unknown { return teamsJSON("", status: 201) }
        let filename = request.url!.path.components(separatedBy: ":/")[1].components(separatedBy: ":")[0]
        let body = try JSONSerialization.data(withJSONObject: ["id": "uploaded", "name": filename, "size": 4, "eTag": "etag1", "file": ["mimeType": "text/plain"], "parentReference": ["driveId": "drive", "id": "folder"], "webUrl": "https://test.sharepoint.com/file.txt"])
        return TeamsHTTPResponse(status: 201, headers: [:], body: body)
    }
}

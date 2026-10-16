import Foundation
import CryptoKit

public struct TeamsRemoteFile: Codable, Sendable {
    public let driveID: String
    public let itemID: String
    public let versionID: String?
    public let eTag: String?
    public let name: String
    public let size: Int64
    public let webURL: URL?
    public init(driveID: String, itemID: String, versionID: String?, eTag: String?, name: String, size: Int64, webURL: URL?) {
        self.driveID = driveID; self.itemID = itemID; self.versionID = versionID; self.eTag = eTag
        self.name = name; self.size = size; self.webURL = webURL
    }
}
public struct TeamsFileRecipient: Codable, Sendable {
    public let userID: String
    public let tenantID: String
    public let displayName: String
    public let email: String?
    public init(userID: String, tenantID: String, displayName: String, email: String?) {
        self.userID = userID; self.tenantID = tenantID; self.displayName = displayName; self.email = email
    }
}
struct TeamsFileRoster: Codable, Sendable {
    let scope: TeamsScope
    let recipients: [TeamsFileRecipient]
    let membershipDigest: String
}
public enum TeamsFileDestination: Codable, Sendable {
    case ownDrive(folderID: String)
    case channel(teamID: String, channelID: String)
}
struct TeamsFileFolder: Codable, Sendable {
    let driveID: String
    let itemID: String
    let name: String
    let ownerVerified: Bool
}
struct TeamsDriveItem: Codable, Sendable {
    struct Parent: Codable, Sendable { let driveId: String; let id: String? }
    struct File: Codable, Sendable { let mimeType: String? }
    struct Folder: Codable, Sendable { let childCount: Int? }
    let id: String
    let name: String
    let size: Int64?
    let eTag: String?
    let parentReference: Parent?
    let file: File?
    let folder: Folder?
    let webUrl: URL?
    let remoteItem: TeamsGraphMetadata?
    func remote(driveID: String? = nil) throws -> TeamsRemoteFile {
        guard !id.isEmpty, let drive = parentReference?.driveId ?? driveID, !drive.isEmpty, file != nil,
              let size, size >= 0, size <= 100 * 1024 * 1024, remoteItem == nil else { throw TeamsFailure.invalidResponse }
        return TeamsRemoteFile(driveID: drive, itemID: id, versionID: nil, eTag: eTag, name: name, size: size, webURL: webUrl)
    }
}

actor TeamsGraphFiles {
    let context: TeamsAccountContext
    let transport: any TeamsHTTPTransport
    let graph: TeamsGraphClient
    init(context: TeamsAccountContext, transport: any TeamsHTTPTransport) {
        self.context = context; self.transport = transport
        graph = TeamsGraphClient(context: context, transport: transport)
    }
    func validate(_ scope: TeamsScope) throws {
        guard scope.accountID == context.accountID, Data(scope.tenantID.utf8) == Data(context.principal.tenantID.utf8) else { throw TeamsFailure.invalidResource }
    }
    func upload(_ prepared: TeamsPreparedFile, from file: URL, folder: TeamsFileFolder, targetID: UUID,
                token: String, capabilities: Set<TeamsCapability>) async throws -> TeamsRemoteFile {
        try validate(prepared.scope)
        guard !capabilities.isDisjoint(with: [.writeFiles, .writeSharedFiles]), folder.ownerVerified,
              prepared.size >= 0, prepared.size <= 100 * 1024 * 1024 else { throw TeamsFailure.forbidden }
        let suffix = prepared.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        let name = targetID.uuidString.lowercased() + "-" + String(suffix.prefix(160))
        let encodedName = try TeamsGraphURL.path([name]).dropFirst("/v1.0/".count)
        let path = try TeamsGraphURL.path(["drives", folder.driveID, "items", folder.itemID]) + ":/" + encodedName + ":/content"
        var parts = URLComponents(); parts.scheme = "https"; parts.host = "graph.microsoft.com"; parts.percentEncodedPath = path
        parts.queryItems = [URLQueryItem(name: "@microsoft.graph.conflictBehavior", value: "fail")]
        guard let url = parts.url else { throw TeamsFailure.invalidResource }
        var request = URLRequest(url: url, timeoutInterval: 30); request.httpMethod = "PUT"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(prepared.size), forHTTPHeaderField: "Content-Length")
        let response: TeamsHTTPResponse
        do { response = try await transport.upload(file: file, to: request) }
        catch { throw TeamsFailure.uncertainSubmission }
        if (400..<500).contains(response.status), response.status != 408 { throw TeamsFailure.server(status: response.status) }
        guard response.status == 201, response.body.count <= 4 * 1024 * 1024,
              let item = try? JSONDecoder().decode(TeamsDriveItem.self, from: response.body),
              item.name == name, item.size == prepared.size,
              item.parentReference?.driveId == folder.driveID, item.parentReference?.id == folder.itemID,
              let remote = try? item.remote(), let web = remote.webURL,
              web.scheme == "https", web.host != nil, web.user == nil, web.password == nil else { throw TeamsFailure.uncertainSubmission }
        return remote
    }
    func request(_ components: [String], token: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        var url = URLComponents(); url.scheme = "https"; url.host = "graph.microsoft.com"; url.percentEncodedPath = try TeamsGraphURL.path(components)
        guard let target = url.url else { throw TeamsFailure.invalidResource }
        var request = URLRequest(url: target, timeoutInterval: 30)
        request.httpMethod = method; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let json { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        return request
    }
    func get<T: Decodable & Sendable>(_ type: T.Type, components: [String], token: String) async throws -> T {
        let response = try await graph.read(request(components, token: token))
        do { return try JSONDecoder().decode(type, from: response.body) } catch { throw TeamsFailure.invalidResponse }
    }
    func folder(destination: TeamsFileDestination, roster: TeamsFileRoster, token: String,
                capabilities: Set<TeamsCapability>) async throws -> TeamsFileFolder {
        guard !capabilities.isDisjoint(with: [.writeFiles, .writeSharedFiles]) else { throw TeamsFailure.forbidden }
        let item: TeamsDriveItem
        var owner = false
        switch destination {
        case let .ownDrive(folderID):
            struct Drive: Decodable, Sendable { struct Owner: Decodable, Sendable { struct User: Decodable, Sendable { let id: String }; let user: User? }; let id: String; let owner: Owner? }
            let drive = try await get(Drive.self, components: ["me", "drive"], token: token)
            owner = UUID(uuidString: drive.owner?.user?.id ?? "") == UUID(uuidString: context.principal.userID)
            item = try await get(TeamsDriveItem.self, components: ["drives", drive.id, "items", folderID], token: token)
        case let .channel(team, channel):
            guard roster.scope.resource == .channel(teamID: team, channelID: channel) else { throw TeamsFailure.invalidResource }
            item = try await get(TeamsDriveItem.self, components: ["teams", team, "channels", channel, "filesFolder"], token: token)
        }
        guard item.folder != nil, item.remoteItem == nil, let drive = item.parentReference?.driveId, !item.id.isEmpty else { throw TeamsFailure.invalidResponse }
        let response = try await graph.read(request(["drives", drive, "items", item.id, "permissions"], token: token))
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              json["@odata.nextLink"] == nil, let permissions = json["value"] as? [[String: Any]] else { throw TeamsFailure.incompleteGrant }
        let allowed = Set(roster.recipients.map { $0.userID.lowercased() } + [context.principal.userID.lowercased()])
        for permission in permissions {
            guard permission["link"] == nil, permission["invitation"] == nil, permission["error"] == nil,
                  let roles = permission["roles"] as? [String], !roles.isEmpty else { throw TeamsFailure.incompleteGrant }
            let single = (permission["grantedToV2"] ?? permission["grantedTo"]) as? [String: Any]
            let identities = (permission["grantedToIdentitiesV2"] ?? permission["grantedToIdentities"]) as? [[String: Any]] ?? single.map { [$0] } ?? []
            guard !identities.isEmpty else { throw TeamsFailure.incompleteGrant }
            for identity in identities {
                guard identity["group"] == nil, identity["siteGroup"] == nil, identity["application"] == nil,
                      let user = identity["user"] as? [String: Any], let id = user["id"] as? String,
                      allowed.contains(id.lowercased()) else { throw TeamsFailure.incompleteGrant }
                if UUID(uuidString: id) != UUID(uuidString: context.principal.userID), roles != ["read"] { throw TeamsFailure.incompleteGrant }
                if UUID(uuidString: id) == UUID(uuidString: context.principal.userID), roles.contains("owner") { owner = true }
            }
        }
        // A nonowner receives only a partial permission list. It cannot prove the audience.
        guard owner else { throw TeamsFailure.incompleteGrant }
        return TeamsFileFolder(driveID: drive, itemID: item.id, name: item.name, ownerVerified: true)
    }
    static func canRead(_ capabilities: Set<TeamsCapability>) -> Bool {
        !capabilities.isDisjoint(with: [.readFiles, .readSharedFiles, .writeFiles, .writeSharedFiles, .resolveSharedLink])
    }
    func resolveSharedURL(_ url: URL, token: String, capabilities: Set<TeamsCapability>) async throws -> TeamsRemoteFile {
        guard !capabilities.isDisjoint(with: [.resolveSharedLink, .writeFiles, .writeSharedFiles]) else { throw TeamsFailure.forbidden }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.port == nil || parts.port == 443,
              url.absoluteString.utf8.count <= 8192 else { throw TeamsFailure.invalidResource }
        let share = "u!" + Data(url.absoluteString.utf8).teamsBase64URL
        // No Prefer redemption headers: resolving a link never grants durable or temporary extra access.
        // The bounded encoded URL can exceed an ordinary opaque item's 1024-byte limit.
        var targetParts = URLComponents(); targetParts.scheme = "https"; targetParts.host = "graph.microsoft.com"
        targetParts.percentEncodedPath = "/v1.0/shares/" + share + "/driveItem"
        guard let target = targetParts.url else { throw TeamsFailure.invalidResource }
        var request = URLRequest(url: target, timeoutInterval: 30); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let response = try await graph.read(request)
        guard let item = try? JSONDecoder().decode(TeamsDriveItem.self, from: response.body) else { throw TeamsFailure.invalidResponse }
        return try item.remote()
    }
    func currentContentRequest(_ original: TeamsRemoteFile, token: String, capabilities: Set<TeamsCapability>) async throws -> URLRequest {
        guard Self.canRead(capabilities) else { throw TeamsFailure.forbidden }
        if let version = original.versionID {
            return try request(["drives", original.driveID, "items", original.itemID, "versions", version, "content"], token: token)
        }
        guard let tag = original.eTag, !tag.isEmpty else { throw TeamsFailure.historicalFileUnavailable }
        let current = try await get(TeamsDriveItem.self, components: ["drives", original.driveID, "items", original.itemID], token: token).remote(driveID: original.driveID)
        guard Data(current.itemID.utf8) == Data(original.itemID.utf8), Data(current.driveID.utf8) == Data(original.driveID.utf8),
              current.eTag.map({ Data($0.utf8) }) == Data(tag.utf8), current.size == original.size else { throw TeamsFailure.historicalFileUnavailable }
        return try request(["drives", original.driveID, "items", original.itemID, "content"], token: token)
    }
    func verifyUnchanged(_ original: TeamsRemoteFile, token: String) async throws {
        if original.versionID != nil { return }
        let current = try await get(TeamsDriveItem.self, components: ["drives", original.driveID, "items", original.itemID], token: token).remote(driveID: original.driveID)
        guard let tag = original.eTag, current.eTag.map({ Data($0.utf8) }) == Data(tag.utf8), current.size == original.size else { throw TeamsFailure.historicalFileUnavailable }
    }
    func download(_ original: TeamsRemoteFile, token: String, capabilities: Set<TeamsCapability>,
                  downloader: any TeamsFileDownloading) async throws -> TeamsFileLease {
        let request = try await currentContentRequest(original, token: token, capabilities: capabilities)
        let lease = try await download(request: request, name: original.name, expectedSize: original.size, downloader: downloader)
        do { try await verifyUnchanged(original, token: token); return lease }
        catch { await lease.release(); throw error }
    }
    func download(request: URLRequest, name: String, expectedSize: Int64?, downloader: any TeamsFileDownloading) async throws -> TeamsFileLease {
        guard let origin = request.url, TeamsGraphURL.accepts(origin), expectedSize == nil || (0...100 * 1024 * 1024).contains(expectedSize!) else { throw TeamsFailure.invalidResource }
        let (directory, destination) = try TeamsFileLease.destination(suffix: URL(fileURLWithPath: name).pathExtension)
        let lease = TeamsFileLease(url: destination, directory: directory)
        do {
            var response = try await downloader.download(request, to: destination, maximumBytes: 100 * 1024 * 1024)
            if response.status == 302 {
                guard let location = response.header("Location"), let url = URL(string: location), let host = url.host?.lowercased(),
                      url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil, url.port == nil || url.port == 443,
                      ["sharepoint.com", "sharepointonline.com", "1drv.com", "onedrive.com", "files.1drv.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { throw TeamsFailure.redirectRejected }
                // Only the trusted Graph response supplies this target. Never copy credentials/headers to it.
                var redirected = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                redirected.httpMethod = "GET"; redirected.httpShouldHandleCookies = false
                response = try await downloader.download(redirected, to: destination, maximumBytes: 100 * 1024 * 1024)
            }
            guard response.status == 200, expectedSize == nil || response.byteCount == expectedSize else { throw TeamsFailure.historicalFileUnavailable }
            return lease
        } catch { await lease.release(); throw error }
    }
    func roster(scope: TeamsScope, token: String, capabilities: Set<TeamsCapability>) async throws -> TeamsFileRoster {
        try validate(scope)
        if case .chat = scope.policyScope.resource {
            guard capabilities.contains(.basicChats) else { throw TeamsFailure.forbidden }
        } else { guard capabilities.contains(.channelMembers) else { throw TeamsFailure.forbidden } }
        let collection = TeamsCollection(context: context, kind: .members(scope.policyScope.resource))
        var cursor: TeamsContinuation?
        var members: [TeamsGraphMember] = []
        var membershipIDs = Set<Data>()
        repeat {
            try Task.checkCancellation()
            let page = try await graph.page(TeamsGraphMember.self, collection: collection, continuation: cursor, token: token)
            guard page.continuationFailure == nil else { throw TeamsFailure.incompleteRoster }
            for member in page.values {
                guard !member.id.isEmpty, membershipIDs.insert(Data(member.id.utf8)).inserted,
                      member.userId.flatMap(UUID.init(uuidString:)) != nil, member.tenantId.flatMap(UUID.init(uuidString:)) != nil,
                      member.displayName?.isEmpty == false else { throw TeamsFailure.incompleteRoster }
                // An unresolved cross-tenant/guest object must not be guessed into this drive's ACL.
                guard Data((member.tenantId ?? "").utf8) == Data(context.principal.tenantID.utf8) else { throw TeamsFailure.incompleteRoster }
                members.append(member)
            }
            cursor = page.next
            if members.count % 100 == 0 { await Task.yield() }
        } while cursor != nil
        guard members.contains(where: { UUID(uuidString: $0.userId ?? "") == UUID(uuidString: context.principal.userID) }) else { throw TeamsFailure.incompleteRoster }
        members.sort { Data($0.id.utf8).lexicographicallyPrecedes(Data($1.id.utf8)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = Data(SHA256.hash(data: scope.policyScope.storageKey + (try encoder.encode(members)))).teamsBase64URL
        let recipients = members.filter { UUID(uuidString: $0.userId ?? "") != UUID(uuidString: context.principal.userID) }.map {
            TeamsFileRecipient(userID: $0.userId!, tenantID: $0.tenantId!, displayName: $0.displayName!, email: $0.email)
        }
        return TeamsFileRoster(scope: scope.policyScope, recipients: recipients, membershipDigest: digest)
    }
    func recheckRoster(_ original: TeamsFileRoster, scope: TeamsScope, token: String, capabilities: Set<TeamsCapability>) async throws {
        guard original.scope == scope.policyScope else { throw TeamsFailure.rosterChanged }
        let current = try await roster(scope: scope, token: token, capabilities: capabilities)
        guard current.membershipDigest == original.membershipDigest else { throw TeamsFailure.rosterChanged }
    }
    func verifyInheritedRead(_ file: TeamsRemoteFile, folder: TeamsFileFolder, roster: TeamsFileRoster, token: String, capabilities: Set<TeamsCapability>) async throws {
        guard capabilities.contains(.writeSharedFiles), folder.ownerVerified,
              case .channel = roster.scope.resource, file.driveID == folder.driveID else { throw TeamsFailure.incompleteGrant }
        let response = try await graph.read(request(["drives", file.driveID, "items", file.itemID, "permissions"], token: token))
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              json["@odata.nextLink"] == nil, let permissions = json["value"] as? [[String: Any]] else { throw TeamsFailure.incompleteGrant }
        let expected = Set(roster.recipients.map { $0.userID.lowercased() })
        let own = context.principal.userID.lowercased()
        var readers = Set<String>(), owner = false
        for permission in permissions {
            guard permission["link"] == nil, permission["invitation"] == nil, permission["error"] == nil,
                  let roles = permission["roles"] as? [String], !roles.isEmpty else { throw TeamsFailure.incompleteGrant }
            let single = (permission["grantedToV2"] ?? permission["grantedTo"]) as? [String: Any]
            let identities = (permission["grantedToIdentitiesV2"] ?? permission["grantedToIdentities"]) as? [[String: Any]] ?? single.map { [$0] } ?? []
            guard !identities.isEmpty else { throw TeamsFailure.incompleteGrant }
            for identity in identities {
                guard identity["group"] == nil, identity["siteGroup"] == nil, identity["application"] == nil,
                      let user = identity["user"] as? [String: Any], let id = (user["id"] as? String)?.lowercased() else { throw TeamsFailure.incompleteGrant }
                if id == own { if roles.contains("owner") { owner = true }; continue }
                guard expected.contains(id), roles == ["read"], let inherited = permission["inheritedFrom"] as? [String: Any],
                      let drive = inherited["driveId"] as? String, let item = inherited["id"] as? String,
                      Data(drive.utf8) == Data(folder.driveID.utf8), Data(item.utf8) == Data(folder.itemID.utf8) else { throw TeamsFailure.incompleteGrant }
                readers.insert(id)
            }
        }
        guard owner, readers == expected else { throw TeamsFailure.incompleteGrant }
    }

    func grantRead(_ file: TeamsRemoteFile, recipients: [TeamsFileRecipient], token: String, capabilities: Set<TeamsCapability>) async throws {
        guard !capabilities.isDisjoint(with: [.writeFiles, .writeSharedFiles]) else { throw TeamsFailure.forbidden }
        guard !recipients.isEmpty, recipients.allSatisfy({ UUID(uuidString: $0.userID) != nil && Data($0.tenantID.utf8) == Data(context.principal.tenantID.utf8) }) else { throw TeamsFailure.incompleteRoster }
        let request = try request(["drives", file.driveID, "items", file.itemID, "invite"], token: token, method: "POST", json: [
            "recipients": recipients.map { ["objectId": $0.userID] }, "roles": ["read"], "requireSignIn": true, "sendInvitation": false])
        let response = try await transport.response(to: request) // Exactly one grant attempt; no mutation retry.
        guard response.status == 200, response.body.count <= 4 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], let permissions = json["value"] as? [[String: Any]] else { throw TeamsFailure.incompleteGrant }
        var granted = Set<Data>()
        for permission in permissions {
            guard permission["error"] == nil, permission["link"] == nil, permission["roles"] as? [String] == ["read"] else { throw TeamsFailure.incompleteGrant }
            let identities = (permission["grantedToIdentitiesV2"] ?? permission["grantedToIdentities"]) as? [[String: Any]]
            let single = (permission["grantedToV2"] ?? permission["grantedTo"]) as? [String: Any]
            for identity in identities ?? single.map({ [$0] }) ?? [] {
                guard identity["group"] == nil, let user = identity["user"] as? [String: Any], let id = user["id"] as? String else { throw TeamsFailure.incompleteGrant }
                granted.insert(Data(id.utf8))
            }
        }
        guard granted == Set(recipients.map { Data($0.userID.utf8) }) else { throw TeamsFailure.incompleteGrant }
    }
}

#if DEBUG
import Foundation
import MakoshCore

enum TeamsSyntheticData {
    static let accounts = [
        TeamsAccount(id: UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!, name: "Проектная команда · QA", clientID: "a3333333-3333-4333-8333-333333333333", authority: "11111111-1111-4111-8111-111111111111", verifiedPrincipal: .init(tenantID: "11111111-1111-4111-8111-111111111111", userID: "22222222-2222-4222-8222-222222222222", displayName: "Александр Тестовый"), readOnly: false),
        TeamsAccount(id: UUID(uuidString: "b1111111-1111-4111-8111-111111111111")!, name: "Поддержка · QA", clientID: "b3333333-3333-4333-8333-333333333333", authority: "55555555-5555-4555-8555-555555555555", verifiedPrincipal: .init(tenantID: "55555555-5555-4555-8555-555555555555", userID: "66666666-6666-4666-8666-666666666666", displayName: "Второй Тестовый"), readOnly: false)
    ]
    static func context(_ account: TeamsAccount) -> TeamsAccountContext { .init(accountID: account.id, principal: account.verifiedPrincipal!) }
    static func peer(_ account: TeamsAccount) -> TeamsPerson { .init(userID: "88888888-8888-4888-8888-888888888888", tenantID: account.authority, displayName: "Мария Тестовая", email: "maria@example.invalid") }
    static func chats(_ account: TeamsAccount) -> [TeamsConversation] {
        [TeamsConversation(scope: .init(accountID: account.id, tenantID: account.authority, resource: .chat("qa-person")), displayName: "Мария Тестовая", kind: .oneOnOne, members: [peer(account)]),
         TeamsConversation(scope: .init(accountID: account.id, tenantID: account.authority, resource: .chat("qa-group")), displayName: "Обсуждение проекта", kind: .group, members: [peer(account)])]
    }
    static func messages(scope: TeamsScope, account: TeamsAccount) -> [TeamsMessage] {
        let count: Int
        switch scope.resource { case .chat("qa-person"): count = 65; case .thread: count = 3; default: count = 2 }
        return (1...count).map { index in
            TeamsMessage(id: "qa-message-\(index)", scope: scope, body: index == 1 ? "<p>Финальная сверка проекта <b>Макош</b>.</p><p>Переписка, файлы и досье остаются рядом.</p>" : "Тестовое сообщение · \(index). Локальная проверка истории и переходов между аккаунтами.", contentType: index == 1 ? "html" : "text", author: peer(account), createdAt: Date().addingTimeInterval(Double(-index * 60)), modifiedAt: nil, deletedAt: nil,
                attachments: index == 1 ? [TeamsAttachment(id: "qa-attachment", name: "Материалы проекта.txt", contentType: "reference", contentURL: URL(string: "https://qa.sharepoint.com/fixture.txt"))] : [], replyTo: nil)
        }
    }
}

private actor TeamsSyntheticVault: TeamsTokenStoring {
    private var values: [UUID: TeamsTokenBundle] = Dictionary(uniqueKeysWithValues: TeamsSyntheticData.accounts.map { account in
        (account.id, TeamsTokenBundle(accessToken: "synthetic-" + account.id.uuidString, refreshToken: nil, idToken: nil, expiresAt: Date().addingTimeInterval(86400), grantedScopes: Set(TeamsCapability.allCases.flatMap { $0.scopes }), expectedNonce: nil))
    })
    func load(accountID: UUID) throws -> TeamsTokenBundle? { values[accountID] }
    func save(_ bundle: TeamsTokenBundle, accountID: UUID, permit: TeamsAuthorizationPermit?) throws {
        guard values[accountID] != nil else { throw TeamsFailure.invalidResource }
        if let permit { try permit.perform { values[accountID] = bundle } } else { values[accountID] = bundle }
    }
}

private actor TeamsSyntheticHTTP: TeamsHTTPTransport {
    func account(_ request: URLRequest) throws -> TeamsAccount {
        guard let value = request.value(forHTTPHeaderField: "Authorization"), value.hasPrefix("Bearer synthetic-"),
              let id = UUID(uuidString: String(value.dropFirst("Bearer synthetic-".count))), let account = TeamsSyntheticData.accounts.first(where: { $0.id == id }),
              let url = request.url, TeamsGraphURL.accepts(url) else { throw TeamsFailure.invalidResource }
        return account
    }
    func json(_ value: [String: Any], status: Int = 200) throws -> TeamsHTTPResponse { .init(status: status, headers: [:], body: try JSONSerialization.data(withJSONObject: value)) }
    func item(_ account: TeamsAccount, id: String = "qa-root", name: String = "OneDrive", size: Int64? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "name": name, "parentReference": ["driveId": "qa-drive", "id": "qa-root"]]
        if let size { value["size"] = size; value["eTag"] = "qa-etag"; value["file"] = ["mimeType": "text/plain"]; value["webUrl"] = "https://qa.sharepoint.com/fixture.txt" }
        else { value["folder"] = [String: Int]() }
        return value
    }
    func response(to request: URLRequest) async throws -> TeamsHTTPResponse {
        let account = try account(request), principal = account.verifiedPrincipal!, path = request.url!.path
        if request.httpMethod == "POST", path.hasSuffix("/invite") {
            let input = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let users = (input?["recipients"] as? [[String: String]] ?? []).compactMap { $0["objectId"] }
            return try json(["value": users.map { ["roles": ["read"], "grantedToV2": ["user": ["id": $0]]] }])
        }
        if request.httpMethod == "POST", path.hasSuffix("/messages") || path.hasSuffix("/replies") {
            var value = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            value["id"] = "qa-outgoing-" + UUID().uuidString; value["createdDateTime"] = ISO8601DateFormatter().string(from: Date())
            value["from"] = ["user": ["id": principal.userID, "tenantId": principal.tenantID, "displayName": principal.displayName]]
            return try json(value, status: 201)
        }
        guard request.httpMethod == nil || request.httpMethod == "GET" else { throw TeamsFailure.invalidResource }
        if path == "/v1.0/me" { return try json(["id": principal.userID, "displayName": principal.displayName]) }
        if path == "/v1.0/me/drive" { return try json(["id": "qa-drive", "owner": ["user": ["id": principal.userID]]]) }
        if path.hasSuffix("/permissions") { return try json(["value": [["roles": ["owner"], "grantedToV2": ["user": ["id": principal.userID]]]]]) }
        if path.hasSuffix("/members") || path.hasSuffix("/allMembers") {
            let peer = TeamsSyntheticData.peer(account)
            return try json(["value": [["id": "qa-self", "userId": principal.userID, "tenantId": principal.tenantID, "displayName": principal.displayName], ["id": "qa-peer", "userId": peer.userID, "tenantId": peer.tenantID, "displayName": peer.displayName]]])
        }
        if path == "/v1.0/me/drive/root" || path.hasSuffix("/items/qa-root") || path.hasSuffix("/filesFolder") { return try json(item(account)) }
        if path.hasSuffix("/items/qa-documents") { return try json(item(account, id: "qa-documents", name: "Материалы проекта")) }
        if path.hasSuffix("/children") { return try json(["value": path.contains("qa-documents") ? [] : [item(account, id: "qa-documents", name: "Материалы проекта")]]) }
        if path.hasPrefix("/v1.0/shares/") || path.hasSuffix("/items/qa-file") { return try json(item(account, id: "qa-file", name: "Материалы проекта.txt", size: 4)) }
        if path == "/v1.0/me/chats" { return try json(["value": TeamsSyntheticData.chats(account).map { chat in
            ["id": { if case let .chat(id) = chat.scope.resource { return id }; return "" }(), "topic": chat.displayName, "chatType": chat.kind == .oneOnOne ? "oneOnOne" : "group"]
        }]) }
        if path == "/v1.0/me/joinedTeams" { return try json(["value": [["id": "qa-team", "displayName": "Макош · Проект"]]]) }
        if path.hasSuffix("/channels") { return try json(["value": [["id": "qa-channel", "displayName": "Общий"]]]) }
        if path.hasSuffix("/messages") || path.hasSuffix("/replies") { return try json(["value": []]) }
        throw TeamsFailure.invalidResource
    }
    func upload(file: URL, to request: URLRequest) async throws -> TeamsHTTPResponse {
        let account = try account(request), path = request.url!.path
        guard let fragment = path.components(separatedBy: ":/").dropFirst().first, let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber else { throw TeamsFailure.invalidResource }
        let name = fragment, folder = String(path.components(separatedBy: "/items/")[1].components(separatedBy: ":/")[0])
        var value = item(account, id: UUID().uuidString, name: name, size: size.int64Value)
        value["parentReference"] = ["driveId": "qa-drive", "id": folder]
        return try json(value, status: 201)
    }
}
private actor TeamsSyntheticDownloader: TeamsFileDownloading {
    func download(_ request: URLRequest, to destination: URL, maximumBytes: Int64) async throws -> TeamsFileDownloadResponse {
        guard let url = request.url, TeamsGraphURL.accepts(url), maximumBytes >= 4 else { throw TeamsFailure.invalidResource }
        try Data("file".utf8).write(to: destination)
        return .init(status: 200, headers: [:], byteCount: 4)
    }
}
extension TeamsWorker {
    public nonisolated static func synthetic(fileRoot: URL? = nil) -> TeamsWorker {
        TeamsWorker(repository: TeamsRepository(keyProvider: { _, _ in Data(repeating: 0x53, count: 32) }), transport: TeamsSyntheticHTTP(),
            vault: TeamsSyntheticVault(), automaticSync: false, syntheticMode: true, syntheticFileRoot: fileRoot, fileDownloader: TeamsSyntheticDownloader())
    }
    func seedSynthetic() async throws {
        guard try await repository.accounts().isEmpty else { return }
        for account in TeamsSyntheticData.accounts {
            try await repository.saveAccount(account)
            let context = TeamsSyntheticData.context(account)
            let chats = TeamsSyntheticData.chats(account)
            try await repository.saveConversations(chats, collection: .init(context: context, kind: .chats), next: nil, failure: nil)
            try await repository.saveTeams([TeamsTeam(id: "qa-team", displayName: "Макош · Проект")], collection: .init(context: context, kind: .joinedTeams), next: nil, failure: nil)
            try await repository.saveChannels([TeamsChannel(id: "qa-channel", teamID: "qa-team", displayName: "Общий")], collection: .init(context: context, kind: .channels("qa-team")), next: nil, failure: nil)
            if let scope = chats.first?.scope {
                _ = try await repository.prepareOutgoing(scope: scope, content: TeamsDraft(text: "QA — подготовленная попытка"))
                let unknown = try await repository.prepareOutgoing(scope: scope, content: TeamsDraft(text: "QA — результат неизвестен"))
                let claimed = try await repository.claimOutgoing(id: unknown.id, accountID: account.id)
                guard let attempt = claimed.attemptID else { throw TeamsFailure.storage }
                _ = try await repository.settleOutgoing(id: unknown.id, accountID: account.id, attemptID: attempt, outcome: .unknown)
            }
            let scopes = chats.map(\.scope) + [TeamsScope(accountID: account.id, tenantID: account.authority, resource: .channel(teamID: "qa-team", channelID: "qa-channel")), TeamsScope(accountID: account.id, tenantID: account.authority, resource: .thread(teamID: "qa-team", channelID: "qa-channel", rootID: "qa-message-1"))]
            for scope in scopes {
                let kind: TeamsCollection.Kind = { if case .thread = scope.resource { return .replies(scope.resource) }; return .messages(scope.resource) }()
                _ = try await repository.commit(page: TeamsPage(values: TeamsSyntheticData.messages(scope: scope, account: account), next: nil, continuationFailure: nil), collection: .init(context: context, kind: kind), baseline: true)
            }
        }
    }
}
#endif

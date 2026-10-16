import Foundation

/// Wire decoding is deliberately separate from Makosh identity/storage. Hosted-content/file bytes are never decoded.
struct TeamsGraphMessage: Codable, Sendable {
    struct Body: Codable, Sendable { let contentType: String?; let content: String? }
    struct Sender: Codable, Sendable {
        struct User: Codable, Sendable { let id: String?; let displayName: String?; let tenantId: String? }
        let user: User?
    }
    let id: String
    let body: Body?
    let from: Sender?
    let createdDateTime: String?
    let lastModifiedDateTime: String?
    let deletedDateTime: String?
    let replyToId: String?
    let attachments: [TeamsAttachment]?
    let subject: String?
    let summary: String?
    let importance: String?
    let messageType: String?
    let reactions: TeamsGraphMetadata?
    let mentions: TeamsGraphMetadata?
    let eventDetail: TeamsGraphMetadata?
    func message(scope: TeamsScope) throws -> TeamsMessage {
        let formatter = ISO8601DateFormatter()
        func date(_ string: String?) throws -> Date? {
            guard let string else { return nil }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = formatter.date(from: string) { return value }
            formatter.formatOptions = [.withInternetDateTime]
            guard let value = formatter.date(from: string) else { throw TeamsFailure.invalidResponse }; return value
        }
        var metadata = [String: String]()
        for (key, value) in [("subject", subject), ("summary", summary), ("importance", importance), ("messageType", messageType)] { if let value { metadata[key] = value } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for (key, value) in [("reactions", reactions), ("mentions", mentions), ("eventDetail", eventDetail)] {
            if let value { metadata[key] = String(decoding: try encoder.encode(value), as: UTF8.self) }
        }
        let person = from?.user.flatMap { user in
            user.id.map { TeamsPerson(userID: $0, tenantID: user.tenantId ?? "", displayName: user.displayName ?? "", email: nil) }
        }
        var retainedAttachments = attachments ?? []
        if body?.contentType == "html", let html = body?.content {
            let expression = try NSRegularExpression(pattern: "(?:src|href)\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive])
            let prefix = try TeamsGraphURL.path(TeamsCollection.Kind.messages(scope.resource).components + [id, "hostedContents"]) + "/"
            var known = Set(retainedAttachments.map { Data($0.id.utf8) })
            for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let reference = String(html[range])
                let path: String
                if reference.hasPrefix("../hostedContents/") { path = prefix + reference.dropFirst("../hostedContents/".count) }
                else if let url = URL(string: reference), TeamsGraphURL.accepts(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.query == nil { path = parts.percentEncodedPath }
                else { continue }
                guard path.hasPrefix(prefix), path.hasSuffix("/$value") else { continue }
                let encoded = String(path.dropFirst(prefix.count).dropLast("/$value".count))
                guard !encoded.contains("/"), let hostedID = encoded.removingPercentEncoding,
                      (try? TeamsGraphURL.path([hostedID])) != nil, known.insert(Data(hostedID.utf8)).inserted else { continue }
                retainedAttachments.append(TeamsAttachment(id: hostedID, name: "Встроенное вложение", contentType: "makosh/teams-hosted", contentURL: nil))
            }
        }
        return TeamsMessage(id: id, scope: scope, body: body?.content ?? "", contentType: body?.contentType ?? "text", author: person,
            createdAt: try date(createdDateTime), modifiedAt: try date(lastModifiedDateTime), deletedAt: try date(deletedDateTime),
            attachments: retainedAttachments, replyTo: replyToId, metadata: metadata)
    }
}

/// Used only for explicitly whitelisted rich Graph metadata, never arbitrary message/file payloads.
indirect enum TeamsGraphMetadata: Codable, Sendable {
    case string(String), number(Double), bool(Bool), array([TeamsGraphMetadata]), object([String: TeamsGraphMetadata]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([TeamsGraphMetadata].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: TeamsGraphMetadata].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .bool(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

public struct TeamsSyncProgress: Sendable {
    public var pagesRead = 0
    public var restartedCollections = 0
    public var incompleteCollections = 0
    public var failure: TeamsFailure?
}

public actor TeamsSynchronization {
    let context: TeamsAccountContext
    let graph: TeamsGraphClient
    let repository: TeamsRepository
    private var currentProgress = TeamsSyncProgress()
    private var stopped = false
    public init(context: TeamsAccountContext, graph: TeamsGraphClient, repository: TeamsRepository) {
        self.context = context; self.graph = graph; self.repository = repository
    }
    public func progress() -> TeamsSyncProgress { currentProgress }
    public func close() { stopped = true }
    func check() throws { try Task.checkCancellation(); guard !stopped else { throw CancellationError() } }

    public func scan(resource: TeamsResource, token: String) async throws {
        try check()
        let lease = try await repository.acquireLease(kind: .sync, accountID: context.accountID, operationID: UUID())
        do {
            try check()
            currentProgress = TeamsSyncProgress()
            try await scanCollection(resource: resource, token: token)
            try await repository.releaseLease(lease)
        } catch {
            try? await repository.releaseLease(lease)
            throw error
        }
    }
    private func scanCollection(resource: TeamsResource, token: String, initialBaseline: Bool? = nil) async throws {
        try check()
        let kind: TeamsCollection.Kind
        if case .thread = resource { kind = .replies(resource) } else { kind = .messages(resource) }
        let collection = TeamsCollection(context: context, kind: kind)
        let existing = try await repository.checkpoint(collection: collection)
        try check()
        var cursor = existing?.complete == false ? existing?.next : nil
        let baseline = existing?.baselineEstablished != true && initialBaseline != false
        var processedRoots = Set<Data>()
        var cachedReplyFailure: TeamsFailure?
        if case let .channel(teamID, channelID) = resource {
            // A root page's cursor may have committed before one of its reply scans failed.
            // Rediscover every retained root independently of that cursor before resuming it.
            let scope = TeamsScope(accountID: context.accountID, tenantID: context.principal.tenantID, resource: resource)
            var retainedCursor: TeamsRetainedCursor?
            repeat {
                let retained = try await repository.messages(scope: scope, before: retainedCursor, limit: 100)
                try check()
                for root in retained.values {
                    processedRoots.insert(Data(root.id.utf8))
                    do { try await scanCollection(resource: .thread(teamID: teamID, channelID: channelID, rootID: root.id), token: token, initialBaseline: baseline) }
                    catch let failure as TeamsFailure {
                        if failure == .unauthorized { throw failure }
                        if case .throttled = failure { throw failure }
                        cachedReplyFailure = cachedReplyFailure ?? failure
                    }
                }
                retainedCursor = retained.next
            } while retainedCursor != nil
        }
        var restarted = false
        if existing?.continuationFailure != nil { currentProgress.restartedCollections += 1; restarted = true }
        while true {
            try check()
            let page: TeamsPage<TeamsGraphMessage>
            do { page = try await graph.page(TeamsGraphMessage.self, collection: collection, continuation: cursor, token: token) }
            catch {
                try check()
                if cursor != nil, !restarted, Self.invalidCursor(error) {
                    cursor = nil; restarted = true; currentProgress.restartedCollections += 1
                    continue
                }
                currentProgress.incompleteCollections += 1; currentProgress.failure = error as? TeamsFailure ?? .transport
                throw error
            }
            try check()
            let scope = TeamsScope(accountID: context.accountID, tenantID: context.principal.tenantID, resource: resource)
            let messages = try page.values.map { try $0.message(scope: scope) }
            _ = try await repository.commit(page: TeamsPage(values: messages, next: page.next, continuationFailure: page.continuationFailure), collection: collection, baseline: baseline, restartOrder: restarted && cursor == nil)
            try check()
            currentProgress.pagesRead += 1
            // Every root is revisited. Root timestamps/expanded replies never prove a complete reply chain.
            if case let .channel(teamID, channelID) = resource {
                for root in messages {
                    try check()
                    guard !processedRoots.contains(Data(root.id.utf8)) else { continue }
                    processedRoots.insert(Data(root.id.utf8))
                    try await scanCollection(resource: .thread(teamID: teamID, channelID: channelID, rootID: root.id), token: token, initialBaseline: baseline)
                }
            }
            if let failure = page.continuationFailure {
                currentProgress.incompleteCollections += 1; currentProgress.failure = failure
                throw failure
            }
            cursor = page.next
            if currentProgress.pagesRead % 5 == 0 { await Task.yield(); try check() }
            if cursor == nil { break }
        }
        if let cachedReplyFailure { throw cachedReplyFailure }
    }
    private static func invalidCursor(_ error: any Error) -> Bool {
        switch error as? TeamsFailure {
        case .invalidContinuation, .server(status: 400), .server(status: 410): true
        default: false
        }
    }
}

struct TeamsGraphMember: Codable, Sendable {
    let id: String
    let userId: String?
    let tenantId: String?
    let displayName: String?
    let email: String?
}
struct TeamsGraphChat: Codable, Sendable { let id: String; let topic: String?; let chatType: String?; let members: [TeamsGraphMember]? }
struct TeamsGraphChannel: Codable, Sendable { let id: String; let displayName: String }

extension TeamsSynchronization {
    private func directoryPage<Item: Codable & Sendable>(_ type: Item.Type, collection: TeamsCollection,
            continuation: TeamsContinuation?, token: String) async throws -> TeamsPage<Item> {
        do { return try await graph.page(type, collection: collection, continuation: continuation, token: token) }
        catch {
            try check()
            guard continuation != nil, Self.invalidCursor(error) else { throw error }
            currentProgress.restartedCollections += 1
            return try await graph.page(type, collection: collection, continuation: nil, token: token)
        }
    }
    func synchronizeCatalogue(token: String, capabilities: Set<TeamsCapability>) async throws {
        try check()
        let lease = try await repository.acquireLease(kind: .sync, accountID: context.accountID, operationID: UUID())
        do {
            try check()
            currentProgress = TeamsSyncProgress()
            try await catalogue(token: token, capabilities: capabilities)
            try await repository.releaseLease(lease)
        } catch { try? await repository.releaseLease(lease); throw error }
    }
    private func catalogue(token: String, capabilities: Set<TeamsCapability>) async throws {
        let chats = TeamsCollection(context: context, kind: .chats)
        var cursor = try await repository.checkpoint(collection: chats)?.next
        repeat {
            try check()
            let page = try await directoryPage(TeamsGraphChat.self, collection: chats, continuation: cursor, token: token)
            try check()
            let values = page.values.map { chat in
                let members = chat.members?.compactMap { member in member.userId.map {
                    TeamsPerson(userID: $0, tenantID: member.tenantId ?? "", displayName: member.displayName ?? "", email: member.email)
                } }
                let names = (members ?? []).filter { !(UUID(uuidString: $0.userID) == UUID(uuidString: context.principal.userID) && UUID(uuidString: $0.tenantID) == UUID(uuidString: context.principal.tenantID)) }
                    .map(\.displayName).filter { !$0.isEmpty }.joined(separator: ", ")
                let title = chat.topic?.isEmpty == false ? chat.topic! : (names.isEmpty ? "Чат" : names)
                return TeamsConversation(scope: TeamsScope(accountID: context.accountID, tenantID: context.principal.tenantID, resource: .chat(chat.id)),
                    displayName: title, kind: TeamsConversationKind(rawValue: chat.chatType ?? "") ?? .unknown, members: members)
            }
            try await repository.saveConversations(values, collection: chats, next: page.next, failure: page.continuationFailure)
            if let failure = page.continuationFailure { throw failure }
            cursor = page.next; currentProgress.pagesRead += 1
            if currentProgress.pagesRead % 5 == 0 { await Task.yield(); try check() }
        } while cursor != nil
        let conversations = try await repository.conversations(accountID: context.accountID)
        for conversation in conversations {
            try check()
            do { try await scanCollection(resource: conversation.scope.resource, token: token) }
            catch let error as TeamsFailure {
                if error == .unauthorized { throw error }
                if case .throttled = error { throw error }
                currentProgress.failure = error
            }
        }
        guard capabilities.contains(.teams) else { return }
        let teams = TeamsCollection(context: context, kind: .joinedTeams)
        cursor = try await repository.checkpoint(collection: teams)?.next
        repeat {
            let page = try await directoryPage(TeamsTeam.self, collection: teams, continuation: cursor, token: token)
            try check()
            try await repository.saveTeams(page.values, collection: teams, next: page.next, failure: page.continuationFailure)
            if let failure = page.continuationFailure { throw failure }
            cursor = page.next; currentProgress.pagesRead += 1
            if currentProgress.pagesRead % 5 == 0 { await Task.yield(); try check() }
        } while cursor != nil
        for team in try await repository.teams(accountID: context.accountID) {
            try check()
            let channels = TeamsCollection(context: context, kind: .channels(team.id))
            cursor = try await repository.checkpoint(collection: channels)?.next
            repeat {
                let page = try await directoryPage(TeamsGraphChannel.self, collection: channels, continuation: cursor, token: token)
                try check()
                try await repository.saveChannels(page.values.map { TeamsChannel(id: $0.id, teamID: team.id, displayName: $0.displayName) }, collection: channels, next: page.next, failure: page.continuationFailure)
                if let failure = page.continuationFailure { throw failure }
                cursor = page.next; currentProgress.pagesRead += 1
                if currentProgress.pagesRead % 5 == 0 { await Task.yield(); try check() }
            } while cursor != nil
            if capabilities.contains(.channelHistory) {
                for channel in try await repository.channels(accountID: context.accountID, teamID: team.id) {
                    try check()
                    do { try await scanCollection(resource: .channel(teamID: team.id, channelID: channel.id), token: token) }
                    catch let error as TeamsFailure {
                        if error == .unauthorized { throw error }
                        if case .throttled = error { throw error }
                        currentProgress.failure = error
                    }
                }
            }
        }
    }
}

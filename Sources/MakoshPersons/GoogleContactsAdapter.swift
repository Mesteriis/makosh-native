import Foundation
import MakoshCore
import MakoshGoogle

/// Google People API v1 through the user's grant, which must carry the contacts scope.
public struct GoogleContactsAdapter: PersonBookAdapter {
    static let base = "https://people.googleapis.com/v1"
    let grant: GoogleGrant
    let oauth: GoogleOAuth
    let http: PersonsHTTP

    public init(grant: GoogleGrant, oauth: GoogleOAuth, http: PersonsHTTP) {
        self.grant = grant
        self.oauth = oauth
        self.http = http
    }

    public var capabilities: PersonBookCapabilities {
        get async { PersonBookCapabilities(acceptsOrganizations: true, requiresPhoneOrPeer: false, supportsMarker: true) }
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> URLRequest {
        var components = URLComponents(string: Self.base + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        let token = try await PersonsFailure.mapGoogle { try await oauth.accessToken(for: grant) }
        request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest, stage: String) async throws -> Data {
        do { return try await http.send(request, stage: stage).0 } catch PersonsFailure.rejected(code: 401, _) {
            throw PersonsFailure.signInRequired
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, stage: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw PersonsFailure.invalidInput(stage) }
    }

    private func encode(_ person: GoogleContactsMapping.GooglePerson) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(person)
    }

    public func changes(cursor: Data?) async throws -> RemoteCardChanges {
        if let cursor, let token = String(data: cursor, encoding: .utf8), !token.isEmpty {
            do { return try await read(syncToken: token) } catch PersonsFailure.rejected(code: 410, _) {}
        }
        return try await read(syncToken: nil)
    }

    private func read(syncToken: String?) async throws -> RemoteCardChanges {
        var result = RemoteCardChanges(cards: [], cursor: nil, full: syncToken == nil)
        var page: String?
        repeat {
            var query = [
                URLQueryItem(name: "personFields", value: GoogleContactsMapping.personFields),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "requestSyncToken", value: "true"),
            ]
            if let syncToken { query.append(.init(name: "syncToken", value: syncToken)) }
            if let page { query.append(.init(name: "pageToken", value: page)) }
            let data = try await send(try await request("/people/me/connections", query: query), stage: "connections")
            let decoded = try decode(GoogleContactsMapping.Page.self, data, stage: "connections")
            for person in decoded.connections ?? [] {
                if person.metadata?.deleted == true {
                    if let id = person.resourceName { result.removedExternalIDs.append(id) }
                    continue
                }
                if let card = GoogleContactsMapping.remoteCard(person) { result.cards.append(card) }
            }
            page = decoded.nextPageToken
            if page == nil { result.cursor = decoded.nextSyncToken.map { Data($0.utf8) } }
        } while page != nil
        return result
    }

    private func write(_ request: URLRequest, stage: String) async throws -> RemoteCardRef {
        let data = try await send(request, stage: stage)
        let person = try decode(GoogleContactsMapping.GooglePerson.self, data, stage: stage)
        guard let id = person.resourceName else { throw PersonsFailure.invalidInput(stage) }
        return RemoteCardRef(externalID: id, etag: person.etag)
    }

    public func create(_ card: PersonCard) async throws -> RemoteCardRef {
        try await write(
            try await request(
                "/people:createContact", query: [URLQueryItem(name: "personFields", value: GoogleContactsMapping.personFields)],
                method: "POST",
                body: try encode(GoogleContactsMapping.body(for: card, etag: nil))), stage: "create")
    }

    public func update(externalID: String, etag: String?, card: PersonCard) async throws -> RemoteCardRef {
        guard externalID.hasPrefix("people/"), !externalID.contains("?") else { throw PersonsFailure.invalidInput("resource") }
        return try await write(
            try await request(
                "/" + externalID + ":updateContact",
                query: [
                    URLQueryItem(name: "updatePersonFields", value: GoogleContactsMapping.updateFields),
                    URLQueryItem(name: "personFields", value: GoogleContactsMapping.personFields),
                ], method: "PATCH", body: try encode(GoogleContactsMapping.body(for: card, etag: etag))), stage: "update")
    }

    public func delete(externalID: String, etag: String?) async throws {
        guard externalID.hasPrefix("people/"), !externalID.contains("?") else { throw PersonsFailure.invalidInput("resource") }
        do {
            _ = try await send(try await request("/" + externalID + ":deleteContact", method: "DELETE"), stage: "delete")
        } catch PersonsFailure.rejected(code: 404, _) {
            // Already gone.
        }
    }

    /// People API has no filter on client data: the whole list is read and searched here.
    public func find(makoshID: UUID) async throws -> RemoteCardRef? {
        try await read(syncToken: nil).cards.first { $0.makoshID == makoshID }.map {
            RemoteCardRef(externalID: $0.externalID, etag: $0.etag)
        }
    }
}

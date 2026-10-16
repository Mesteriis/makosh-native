import Foundation

public actor TelemostAPI {
    private let transport: any TelemostHTTPTransport
    private let clock: any TelemostRetryClock
    public init(transport: any TelemostHTTPTransport = TelemostURLSessionTransport(), clock: any TelemostRetryClock = TelemostSystemRetryClock()) {
        self.transport = transport; self.clock = clock
    }
    public func conference(scope: TelemostScope, token: String) async throws -> TelemostConference {
        let body = try await exchange(method: "GET", path: try path(scope), token: token)
        return try decodeConference(body, accountID: scope.accountID, expectedID: scope.conferenceID)
    }
    public func cohosts(scope: TelemostScope, offset: Int, limit: Int, token: String) async throws -> TelemostCohostPage {
        guard offset >= 0, offset <= 100_000, limit > 0, limit <= 100 else { throw TelemostFailure.invalidConfiguration }
        let body = try await exchange(method: "GET", path: try path(scope) + "/cohosts?offset=\(offset)&limit=\(limit)", token: token)
        struct Wire: Decodable { struct Person: Decodable { let email: String }; let cohosts: [Person] }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: body), wire.cohosts.count <= limit else { throw TelemostFailure.invalidResponse }
        let emails = wire.cohosts.map(\.email)
        guard emails.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw TelemostFailure.invalidResponse }
        return TelemostCohostPage(scope: scope, offset: offset, limit: limit, emails: emails, complete: emails.count < limit)
    }
    public func create(accountID: UUID, request: TelemostCreateRequest, token: String) async throws -> TelemostConference {
        let body = try await exchange(method: "POST", path: "", token: token, waitingRoom: request.waitingRoom)
        return try decodeConference(body, accountID: accountID, expectedID: nil)
    }
    public func update(scope: TelemostScope, patch: TelemostMeetingPatch, token: String) async throws -> TelemostConference {
        let body = try await exchange(method: "PATCH", path: try path(scope), token: token, waitingRoom: patch.waitingRoom)
        return try decodeConference(body, accountID: scope.accountID, expectedID: scope.conferenceID)
    }
    private func path(_ scope: TelemostScope) throws -> String {
        guard !scope.conferenceID.isEmpty, scope.conferenceID.utf8.count <= 1024,
              scope.conferenceID.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }),
              let encoded = scope.conferenceID.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) else {
            throw TelemostFailure.invalidConfiguration
        }
        return "/" + encoded
    }
    private func exchange(method: String, path: String, token: String, waitingRoom: TelemostWaitingRoom? = nil) async throws -> Data {
        guard !token.isEmpty, token.utf8.count <= 128 * 1024,
              token.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
              let url = URL(string: "https://cloud-api.yandex.net/v1/telemost-api/conferences" + path) else { throw TelemostFailure.invalidConfiguration }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let waitingRoom {
            request.httpBody = try JSONEncoder().encode(["waiting_room_level": waitingRoom.rawValue])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let response = try await transport.response(to: request)
            guard response.body.count <= 4 * 1024 * 1024 else { throw TelemostFailure.bodyTooLarge }
            if (200..<300).contains(response.status) { return response.body }
            if method == "GET", [429, 503].contains(response.status), attempt < 2 {
                let value = response.headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value
                let raw = value.flatMap(TimeInterval.init) ?? Double(attempt + 1)
                guard raw.isFinite, raw >= 0, raw <= 30 else { throw TelemostFailure.provider(response.status) }
                try await clock.sleep(seconds: raw); continue
            }
            switch response.status {
            case 401: throw TelemostFailure.unauthorized
            case 403: throw TelemostFailure.forbidden
            case 404: throw TelemostFailure.missing
            case 300..<400: throw TelemostFailure.redirectRejected
            default: throw TelemostFailure.provider(response.status)
            }
        }
        throw TelemostFailure.transport
    }
    private func decodeConference(_ body: Data, accountID: UUID, expectedID: String?) throws -> TelemostConference {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= 1024,
              let address = object["join_url"] as? String, let url = try? TelemostMeetingURL(address),
              url.conferenceID.utf8.elementsEqual(id.utf8),
              expectedID.map({ $0.utf8.elementsEqual(id.utf8) }) ?? true else { throw TelemostFailure.invalidResponse }
        let raw = object["waiting_room_level"] as? String ?? object["access_level"] as? String ?? "UNKNOWN"
        guard raw.utf8.count <= 1024 else { throw TelemostFailure.invalidResponse }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return TelemostConference(scope: .init(accountID: accountID, conferenceID: id), joinURL: url, waitingRoomRaw: raw, retainedJSON: canonical)
    }
}

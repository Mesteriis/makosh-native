import Foundation
import CryptoKit

private struct TeamsGraphEnvelope<Item: Codable & Sendable>: Codable {
    let value: [Item]
    let nextLink: URL?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
}

public actor TeamsGraphClient {
    let context: TeamsAccountContext
    let transport: any TeamsHTTPTransport
    let retryClock: any TeamsRetryClock
    public init(context: TeamsAccountContext, transport: any TeamsHTTPTransport, retryClock: any TeamsRetryClock = TeamsSystemRetryClock()) {
        self.context = context; self.transport = transport; self.retryClock = retryClock
    }

    public func page<Item: Codable & Sendable>(_ type: Item.Type, collection: TeamsCollection,
            continuation: TeamsContinuation?, token: String, limit: Int = 50) async throws -> TeamsPage<Item> {
        guard collection.context == context else { throw TeamsFailure.invalidContinuation }
        let path = try TeamsGraphURL.path(collection.kind.components)
        let url: URL
        if let continuation {
            guard continuation.owner == collection, TeamsGraphURL.accepts(continuation.url, path: path) else {
                throw TeamsFailure.invalidContinuation
            }
            url = continuation.url
        } else {
            var components = URLComponents()
            components.scheme = "https"; components.host = "graph.microsoft.com"
            components.percentEncodedPath = path
            switch collection.kind {
            case .chats:
                components.queryItems = [URLQueryItem(name: "$top", value: String(min(50, max(1, limit)))), URLQueryItem(name: "$expand", value: "members")]
            case .messages, .replies, .driveFolders:
                components.queryItems = [URLQueryItem(name: "$top", value: String(min(50, max(1, limit))))]
            case .joinedTeams, .channels, .members:
                break // These catalogue endpoints do not support $top; retain the complete response/nextLink.
            }
            guard let built = components.url else { throw TeamsFailure.invalidResource }
            url = built
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let response = try await read(request)
        let envelope: TeamsGraphEnvelope<Item>
        do { envelope = try JSONDecoder().decode(TeamsGraphEnvelope<Item>.self, from: response.body) }
        catch { throw TeamsFailure.invalidResponse }
        var visited = continuation?.visited ?? []
        visited.insert(Data(SHA256.hash(data: Data(url.absoluteString.utf8))))
        if let next = envelope.nextLink {
            guard TeamsGraphURL.accepts(next, path: path), !visited.contains(Data(SHA256.hash(data: Data(next.absoluteString.utf8)))) else {
                return TeamsPage(values: envelope.value, next: nil, continuationFailure: .invalidContinuation)
            }
            return TeamsPage(values: envelope.value, next: TeamsContinuation(owner: collection, url: next, visited: visited), continuationFailure: nil)
        }
        return TeamsPage(values: envelope.value, next: nil, continuationFailure: nil)
    }

    public func identity(token: String) async throws -> TeamsGraphUser {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!, timeoutInterval: 30)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do { return try JSONDecoder().decode(TeamsGraphUser.self, from: try await read(request).body) }
        catch let error as TeamsFailure { throw error }
        catch { throw TeamsFailure.invalidResponse }
    }

    func read(_ request: URLRequest) async throws -> TeamsHTTPResponse {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let response = try await transport.response(to: request)
            try Task.checkCancellation()
            guard response.body.count <= 4 * 1024 * 1024 else { throw TeamsFailure.bodyTooLarge }
            if response.status == 200 { return response }
            if response.status == 401 { throw TeamsFailure.unauthorized }
            if response.status == 403 { throw TeamsFailure.forbidden }
            if response.status == 429 || response.status == 503 || response.status == 502 || response.status == 504 {
                let delay = retryAfter(response.header("Retry-After"), fallback: TimeInterval(attempt + 1))
                guard attempt < 2, delay <= 30 else { throw TeamsFailure.throttled(retryAfter: delay) }
                try await retryClock.sleep(seconds: delay)
                continue
            }
            throw TeamsFailure.server(status: response.status)
        }
        throw TeamsFailure.transport
    }

    private func retryAfter(_ value: String?, fallback: TimeInterval) -> TimeInterval {
        guard let value else { return fallback }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return max(0, date.timeIntervalSinceNow) }
        return fallback
    }
}

enum TeamsGraphURL {
    static func path(_ components: [String]) throws -> String {
        guard !components.isEmpty else { throw TeamsFailure.invalidResource }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = try components.map { component -> String in
            guard !component.isEmpty, component != ".", component != "..", component.utf8.count <= 1024,
                  !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let result = component.addingPercentEncoding(withAllowedCharacters: allowed) else { throw TeamsFailure.invalidResource }
            return result
        }
        return "/v1.0/" + encoded.joined(separator: "/")
    }

    static func accepts(_ url: URL, path: String? = nil) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host?.lowercased() == "graph.microsoft.com",
              components.port == nil || components.port == 443, components.user == nil, components.password == nil,
              components.fragment == nil, components.percentEncodedPath.hasPrefix("/v1.0/") else { return false }
        return path.map { Data($0.utf8) == Data(components.percentEncodedPath.utf8) } ?? true
    }
}

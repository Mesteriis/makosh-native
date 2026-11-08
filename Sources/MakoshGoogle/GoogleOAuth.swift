import CryptoKit
import Foundation
import MakoshBuildConfiguration
import Network

/// Makosh's Google desktop client, compiled from private build input.
public struct GoogleOAuthClient: Sendable {
    public let clientID: String
    public let clientSecret: String
    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
    public static var embedded: GoogleOAuthClient? {
        guard let id = MakoshGoogleOAuthConfiguration.clientID, let secret = MakoshGoogleOAuthConfiguration.clientSecret else { return nil }
        return GoogleOAuthClient(clientID: id, clientSecret: secret)
    }
}

/// One Google account's consent. The refresh token lives only in the Keychain.
public struct GoogleGrant: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let subject: String
    public let email: String
    public let scopes: Set<String>
    public let refreshToken: String
    public init(subject: String, email: String, scopes: Set<String>, refreshToken: String) {
        self.subject = subject
        self.email = email
        self.scopes = scopes
        self.refreshToken = refreshToken
    }
    public var description: String { "GoogleGrant(\(email))" }
    public var debugDescription: String { description }
}

public struct GoogleAccessToken: Sendable {
    public let value: String
    public let expiresAt: Date
}

/// Why a sign-in or a token refresh did not happen; never the body or the token.
public enum GoogleOAuthFailure: Error, Equatable, Sendable {
    case notConfigured
    /// A Workspace administrator forbids this client, or the user declined consent.
    case adminBlocked
    /// No code arrived, the grant was revoked or the reply lacked what a grant needs.
    case signInRequired
    case transport(stage: String)
    case rejected(code: Int, stage: String)
    /// The loopback listener could not open.
    case listenerUnavailable
}

/// OAuth 2.0 for an installed app: system browser, PKCE S256, a loopback
/// redirect on 127.0.0.1 with a random port that lives only for one sign-in.
public actor GoogleOAuth {
    static let authorization = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let token = URL(string: "https://oauth2.googleapis.com/token")!
    /// Identity scopes every Makosh sign-in asks for; a section adds its own API scope.
    public static let identityScopes = "openid email"
    static let adminErrors: Set<String> = ["admin_policy_enforced", "org_internal", "access_denied"]

    private let client: GoogleOAuthClient
    private let http: ServiceHTTP
    private let openBrowser: @Sendable (URL) -> Void
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    /// The scopes a plain `signIn(loginHint:)` asks for.
    public nonisolated let scopes: String
    private var cache: [String: GoogleAccessToken] = [:]

    public init(
        client: GoogleOAuthClient, http: ServiceHTTP, scopes: String, openBrowser: @escaping @Sendable (URL) -> Void,
        timeout: TimeInterval = 300, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.http = http
        self.scopes = scopes
        self.openBrowser = openBrowser
        self.timeout = timeout
        self.now = now
    }

    public nonisolated var clientID: String { client.clientID }

    public func signIn(loginHint: String?) async throws -> GoogleGrant {
        try await signIn(scopes: scopes, loginHint: loginHint)
    }

    /// One consent for `scopes`; `include_granted_scopes` keeps what an earlier grant already had,
    /// so a section can widen a grant another section obtained.
    public func signIn(scopes: String, loginHint: String?) async throws -> GoogleGrant {
        let verifier = Self.random(), state = Self.random()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let listener = try LoopbackListener()
        defer { listener.close() }
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)"
        var components = URLComponents(url: Self.authorization, resolvingAgainstBaseURL: false)!
        components.queryItems =
            [
                .init(name: "client_id", value: client.clientID), .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes),
                .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
                .init(name: "include_granted_scopes", value: "true"),
            ] + (loginHint.map { [.init(name: "login_hint", value: $0)] } ?? [])
        openBrowser(components.url!)
        let query = try await withThrowingTaskGroup(of: [String: String]?.self) { group in
            group.addTask { await listener.callback(state: state) }
            group.addTask {
                try await Task.sleep(for: .seconds(self.timeout))
                return nil
            }
            let first = try await group.next() ?? nil
            // The waiting callback is not cancellable: closing the listener releases it.
            listener.close()
            group.cancelAll()
            return first
        }
        guard let query else { throw GoogleOAuthFailure.signInRequired }
        if let error = query["error"] {
            throw Self.adminErrors.contains(error) ? GoogleOAuthFailure.adminBlocked : GoogleOAuthFailure.signInRequired
        }
        guard let code = query["code"], !code.isEmpty else { throw GoogleOAuthFailure.signInRequired }
        let reply = try await tokenRequest([
            "code": code, "client_id": client.clientID, "client_secret": client.clientSecret, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        guard let refresh = reply.refreshToken, let identity = reply.idToken.flatMap(Self.identity) else {
            throw GoogleOAuthFailure.signInRequired
        }
        let grant = GoogleGrant(
            subject: identity.sub, email: identity.email ?? "", scopes: Set((reply.scope ?? "").split(separator: " ").map(String.init)),
            refreshToken: refresh)
        if let access = reply.accessToken {
            cache[grant.subject] = GoogleAccessToken(value: access, expiresAt: now().addingTimeInterval(TimeInterval(reply.expiresIn ?? 0)))
        }
        return grant
    }

    public func accessToken(for grant: GoogleGrant) async throws -> GoogleAccessToken {
        if let cached = cache[grant.subject], cached.expiresAt > now().addingTimeInterval(60) { return cached }
        let reply = try await tokenRequest([
            "client_id": client.clientID, "client_secret": client.clientSecret, "refresh_token": grant.refreshToken,
            "grant_type": "refresh_token",
        ])
        guard let access = reply.accessToken else { throw GoogleOAuthFailure.signInRequired }
        let token = GoogleAccessToken(value: access, expiresAt: now().addingTimeInterval(TimeInterval(reply.expiresIn ?? 0)))
        cache[grant.subject] = token
        return token
    }

    public func forget(subject: String) { cache[subject] = nil }

    struct TokenReply: Decodable {
        let accessToken: String?
        let expiresIn: Int?
        let refreshToken: String?
        let scope: String?
        let idToken: String?
        let error: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token", scope, idToken = "id_token", error
        }
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenReply {
        var request = URLRequest(url: Self.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(
            form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&").utf8)
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await http.raw(request, stage: "token") } catch {
            throw GoogleOAuthFailure.transport(stage: "token")
        }
        let reply = try? JSONDecoder().decode(TokenReply.self, from: data)
        guard (200..<300).contains(response.statusCode), let reply, reply.error == nil else {
            switch reply?.error {
            case "invalid_grant"?: throw GoogleOAuthFailure.signInRequired
            case let code? where Self.adminErrors.contains(code): throw GoogleOAuthFailure.adminBlocked
            default:
                if response.statusCode >= 500 { throw GoogleOAuthFailure.transport(stage: "token") }
                throw GoogleOAuthFailure.rejected(code: response.statusCode, stage: "token")
            }
        }
        return reply
    }

    /// The ID token came straight from Google's token endpoint over TLS; its claims are read, not verified.
    static func identity(_ token: String) -> (sub: String, email: String?)? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let sub = object["sub"] as? String
        else { return nil }
        return (sub, object["email"] as? String)
    }

    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP listener on 127.0.0.1 for the OAuth redirect.
final class LoopbackListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.makosh.google.oauth-loopback")
    private let listener: NWListener
    private let lock = NSLock()
    private var waiting: [(state: String, continuation: CheckedContinuation<[String: String]?, Never>)] = []
    private var closed = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        do { listener = try NWListener(using: parameters) } catch { throw GoogleOAuthFailure.listenerUnavailable }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(throwing: GoogleOAuthFailure.listenerUnavailable) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    /// The query of the first redirect whose `state` matches; nil after `close()`.
    func callback(state: String) async -> [String: String]? {
        await withCheckedContinuation { continuation in
            let closedNow = lock.withLock { () -> Bool in
                if closed { return true }
                waiting.append((state, continuation))
                return false
            }
            if closedNow { continuation.resume(returning: nil) }
        }
    }

    func close() {
        let pending = lock.withLock { () -> [CheckedContinuation<[String: String]?, Never>] in
            closed = true
            defer { waiting = [] }
            return waiting.map(\.continuation)
        }
        listener.cancel()
        for continuation in pending { continuation.resume(returning: nil) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let query = data.flatMap { Self.query(fromRequest: $0) } ?? [:]
            let match = self.lock.withLock { () -> CheckedContinuation<[String: String]?, Never>? in
                guard let index = self.waiting.firstIndex(where: { $0.state == query["state"] }) else { return nil }
                return self.waiting.remove(at: index).continuation
            }
            let body = match == nil ? "Запрос не распознан." : "Вход выполнен. Можно вернуться в Makosh."
            let html = "<!doctype html><meta charset=utf-8><title>Makosh</title><p>\(body)</p>"
            let response =
                "HTTP/1.1 \(match == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            match?.resume(returning: query)
        }
    }

    static func query(fromRequest data: Data) -> [String: String]? {
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return nil }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

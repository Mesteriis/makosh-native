import Foundation
import CryptoKit
import Security

public enum TelemostAuthorizationMode: Sendable { case browserCallback, manualCode }
public struct TelemostAuthorizationRequest: Sendable {
    public let id: UUID
    public let accountID: UUID
    public let authURL: URL
    public let expectedCallback: URL
    public let mode: TelemostAuthorizationMode
    public let expiry: Date
}
public struct TelemostToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let capabilities: Set<TelemostCapability>
    public let principal: TelemostPrincipal
    public init(accessToken: String, refreshToken: String?, expiresAt: Date, capabilities: Set<TelemostCapability>, principal: TelemostPrincipal) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.capabilities = capabilities; self.principal = principal
    }
    func validate() throws {
        guard !accessToken.isEmpty, accessToken.utf8.count <= 128 * 1024,
              accessToken.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
              refreshToken.map({ !$0.isEmpty && $0.utf8.count <= 128 * 1024 }) ?? true,
              !principal.userID.isEmpty, principal.userID.utf8.count <= 1024,
              principal.clientID.utf8.count == 32, principal.login.utf8.count <= 1024,
              expiresAt.timeIntervalSince1970.isFinite, capabilities.contains(.read) else { throw TelemostFailure.invalidResponse }
    }
}
public struct TelemostGrantResult: Equatable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let principal: TelemostPrincipal
    public let token: TelemostToken
}
public actor TelemostOAuth {
    private struct Pending {
        let account: TelemostAccount
        let request: TelemostAuthorizationRequest
        let verifier: String
        let state: String
        var inFlight = false
    }
    private let transport: any TelemostHTTPTransport
    private let now: @Sendable () -> Date
    private var pending: [UUID: Pending] = [:]
    private var grants: [UUID: (TelemostGrantResult, Date)] = [:]
    public init(transport: any TelemostHTTPTransport = TelemostURLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport; self.now = now
    }
    public func begin(account: TelemostAccount, mode: TelemostAuthorizationMode) throws -> TelemostAuthorizationRequest {
        let allowed = CharacterSet(charactersIn: "abcdefABCDEF0123456789")
        guard account.clientID.utf8.count == 32, account.clientID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              account.callbackURL.absoluteString == "org.makosh.desktop.telemost://oauth/callback",
              account.capabilities.contains(.read) else { throw TelemostFailure.invalidConfiguration }
        pending = pending.filter { $0.value.request.expiry > now() }
        grants = grants.filter { $0.value.1 > now() }
        guard pending.count < 16 else { throw TelemostFailure.busy }
        cancel(accountID: account.id)
        let verifier = try random(), state = try random(), id = UUID()
        let redirect = mode == .manualCode ? URL(string: "https://oauth.yandex.ru/verification_code")! : account.callbackURL
        var url = URLComponents(string: "https://oauth.yandex.ru/authorize")!
        url.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: account.clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString), .init(name: "force_confirm", value: "yes"),
            .init(name: "scope", value: account.capabilities.map(\.scope).sorted().joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        ]
        guard let authURL = url.url else { throw TelemostFailure.invalidConfiguration }
        let request = TelemostAuthorizationRequest(id: id, accountID: account.id, authURL: authURL, expectedCallback: redirect, mode: mode, expiry: now().addingTimeInterval(600))
        pending[id] = Pending(account: account, request: request, verifier: verifier, state: state)
        return request
    }
    public func complete(id: UUID, callback: URL) async throws -> TelemostGrantResult {
        let value = try active(id)
        guard value.request.mode == .browserCallback,
              let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: value.request.expectedCallback, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host, actual.percentEncodedPath == expected.percentEncodedPath,
              actual.port == expected.port, actual.user == nil, actual.password == nil, actual.fragment == nil else { throw TelemostFailure.invalidResponse }
        let items = actual.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["state", "code", "error", "error_description"].contains($0.name) }),
              items.first(where: { $0.name == "state" })?.value == value.state else { throw TelemostFailure.invalidResponse }
        if items.contains(where: { $0.name == "error" }) { cancel(id: id); throw TelemostFailure.unauthorized }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 4096, code.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else { throw TelemostFailure.invalidResponse }
        return try await exchange(id: id, code: code)
    }
    public func complete(id: UUID, code: String) async throws -> TelemostGrantResult {
        let value = try active(id)
        guard value.request.mode == .manualCode, code.utf8.count == 7, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw TelemostFailure.invalidResponse }
        return try await exchange(id: id, code: code)
    }
    public func cancel(id: UUID) { pending[id] = nil; grants[id] = nil }
    public func cancel(accountID: UUID) {
        pending = pending.filter { $0.value.account.id != accountID }
        grants = grants.filter { $0.value.0.accountID != accountID }
    }
    public func consumeGrant(id: UUID, accountID: UUID) throws -> TelemostGrantResult {
        guard let value = grants[id], value.0.accountID == accountID, value.1 > now() else { throw TelemostFailure.conflict }
        grants[id] = nil; return value.0
    }
    private func active(_ id: UUID) throws -> Pending {
        guard let value = pending[id] else { throw TelemostFailure.conflict }
        guard value.request.expiry > now() else { pending[id] = nil; throw TelemostFailure.expired }
        guard !value.inFlight else { throw TelemostFailure.busy }; return value
    }
    private func exchange(id: UUID, code: String) async throws -> TelemostGrantResult {
        var value = try active(id); value.inFlight = true; pending[id] = value
        defer { pending[id] = nil }
        let fields = ["grant_type": "authorization_code", "client_id": value.account.clientID, "code": code, "code_verifier": value.verifier]
        var request = URLRequest(url: URL(string: "https://oauth.yandex.ru/token")!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents(); form.queryItems = fields.keys.sorted().map { .init(name: $0, value: fields[$0]) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let response = try await transport.response(to: request)
        try stillActive(id)
        guard response.status == 200, response.body.count <= 4 * 1024 * 1024 else { throw TelemostFailure.unauthorized }
        struct Wire: Decodable { let access_token: String; let refresh_token: String?; let token_type: String; let expires_in: TimeInterval; let scope: String? }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: response.body), wire.token_type.lowercased() == "bearer",
              !wire.access_token.isEmpty, wire.access_token.utf8.count <= 128 * 1024, wire.expires_in.isFinite, wire.expires_in > 0,
              wire.access_token.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else { throw TelemostFailure.invalidResponse }
        let capabilities: Set<TelemostCapability>
        if let scopes = wire.scope {
            let raw = Set(scopes.split(separator: " ").map(String.init))
            guard raw.isSubset(of: Set(value.account.capabilities.map(\.scope))) else { throw TelemostFailure.scopeDenied }
            capabilities = Set(value.account.capabilities.filter { raw.contains($0.scope) })
        } else { capabilities = value.account.capabilities }
        guard capabilities.contains(.read) else { throw TelemostFailure.scopeDenied }
        var identity = URLRequest(url: URL(string: "https://login.yandex.ru/info?format=json")!)
        identity.setValue("OAuth " + wire.access_token, forHTTPHeaderField: "Authorization")
        let info = try await transport.response(to: identity); try stillActive(id)
        struct Person: Decodable { let id: String; let client_id: String; let login: String }
        guard info.status == 200, info.body.count <= 4 * 1024 * 1024,
              let person = try? JSONDecoder().decode(Person.self, from: info.body),
              !person.id.isEmpty, person.id.utf8.count <= 1024, person.login.utf8.count <= 1024,
              person.client_id.utf8.elementsEqual(value.account.clientID.utf8) else { throw TelemostFailure.invalidResponse }
        let principal = TelemostPrincipal(userID: person.id, clientID: person.client_id, login: person.login)
        guard value.account.principal.map({ $0.sameSource(as: principal) }) ?? true else { throw TelemostFailure.conflict }
        let token = TelemostToken(accessToken: wire.access_token, refreshToken: wire.refresh_token, expiresAt: now().addingTimeInterval(wire.expires_in), capabilities: capabilities, principal: principal)
        try token.validate()
        let grant = TelemostGrantResult(id: id, accountID: value.account.id, principal: principal, token: token)
        grants[id] = (grant, now().addingTimeInterval(600)); return grant
    }
    private func stillActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard let value = pending[id], value.inFlight else { throw CancellationError() }
        guard value.request.expiry > now() else { throw TelemostFailure.expired }
    }
    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TelemostFailure.keyUnavailable }
        return base64URL(Data(bytes))
    }
    private func base64URL(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// Public delegated OAuth contracts adapted from teams-cli, MIT; see Dependencies/Teams.lock.json.
import Foundation
import CryptoKit
import Security

public struct TeamsOAuthConfiguration: Codable, Equatable, Sendable {
    public let clientID: String
    public let authority: String
    public init(clientID: String, authority: String) { self.clientID = clientID; self.authority = authority }
    func validate() throws {
        guard UUID(uuidString: clientID) != nil,
              authority == "organizations" || UUID(uuidString: authority) != nil,
              authority.lowercased() != "9188040d-6c67-4c5b-b112-36a304b66dad" else { throw TeamsFailure.invalidConfiguration }
    }
    func endpoint(_ suffix: String) throws -> URL {
        try validate()
        guard let url = URL(string: "https://login.microsoftonline.com/\(authority)/\(suffix)") else { throw TeamsFailure.invalidConfiguration }
        return url
    }
}

public enum TeamsCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case basicChats, teams, channelHistory, channelMembers, sendChat, sendChannel, readFiles, readSharedFiles, resolveSharedLink, writeFiles, writeSharedFiles
    public var scopes: Set<String> {
        switch self {
        case .basicChats: ["openid", "profile", "offline_access", "User.Read", "Chat.Read"]
        case .teams: ["Team.ReadBasic.All", "Channel.ReadBasic.All"]
        case .channelHistory: ["ChannelMessage.Read.All"]
        case .channelMembers: ["ChannelMember.Read.All"]
        case .sendChat: ["ChatMessage.Send"]
        case .sendChannel: ["ChannelMessage.Send"]
        case .readFiles: ["Files.Read"]
        case .readSharedFiles: ["Files.Read.All"]
        case .resolveSharedLink, .writeFiles: ["Files.ReadWrite"]
        case .writeSharedFiles: ["Files.ReadWrite.All"]
        }
    }
}

public enum TeamsAuthorizationMethod: String, Codable, Sendable { case browserPKCE, deviceCode }

// Deliberately module-private: UI receives only authorization presentations and account snapshots.
struct TeamsTokenBundle: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Date
    let grantedScopes: Set<String>
    let expectedNonce: String?
}

struct TeamsPKCEChallenge: Sendable {
    let id: UUID
    let configuration: TeamsOAuthConfiguration
    let authorizationURL: URL
    let callbackURL: URL
    let verifier: String
    let state: String
    let nonce: String
    let expiresAt: Date
}

struct TeamsDeviceChallenge: Sendable {
    let id: UUID
    let configuration: TeamsOAuthConfiguration
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

enum TeamsDevicePollResult: Equatable, Sendable {
    case pending(nextPollAt: Date, interval: TimeInterval)
    case authorized(TeamsTokenBundle)
}

extension Data {
    var teamsBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(teamsBase64URL: String) {
        guard !teamsBase64URL.isEmpty, teamsBase64URL.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let padded = teamsBase64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: padded + String(repeating: "=", count: (4 - padded.count % 4) % 4))
    }
}

actor TeamsOAuthClient {
    private let transport: any TeamsHTTPTransport
    private let now: @Sendable () -> Date
    private var pendingPKCE: [UUID: TeamsPKCEChallenge] = [:]
    private var exchangingPKCE = Set<UUID>()
    private struct DeviceState { let challenge: TeamsDeviceChallenge; var interval: TimeInterval; var next: Date; var inFlight = false }
    private var pendingDevice: [UUID: DeviceState] = [:]

    init(transport: any TeamsHTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.now = now
    }

    func beginPKCE(configuration: TeamsOAuthConfiguration, capabilities: Set<TeamsCapability>, callbackURL: URL) throws -> TeamsPKCEChallenge {
        try configuration.validate()
        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false), callback.scheme == "http",
              callback.host == "127.0.0.1", callback.port.map({ (1...65535).contains($0) }) == true,
              callback.path == "/callback", callback.user == nil, callback.password == nil,
              callback.query == nil, callback.fragment == nil else { throw TeamsFailure.invalidConfiguration }
        let verifier = try random(); let state = try random(); let nonce = try random()
        var components = URLComponents(url: try configuration.endpoint("oauth2/v2.0/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = ["client_id": configuration.clientID, "response_type": "code", "response_mode": "query",
            "redirect_uri": callbackURL.absoluteString, "scope": scopes(capabilities), "state": state, "nonce": nonce,
            "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).teamsBase64URL, "code_challenge_method": "S256"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw TeamsFailure.invalidConfiguration }
        let challenge = TeamsPKCEChallenge(id: UUID(), configuration: configuration, authorizationURL: url,
            callbackURL: callbackURL, verifier: verifier, state: state, nonce: nonce, expiresAt: now().addingTimeInterval(300))
        pendingPKCE[challenge.id] = challenge
        return challenge
    }

    func exchange(challenge: TeamsPKCEChallenge, callback: Data) async throws -> TeamsTokenBundle {
        guard let active = pendingPKCE[challenge.id], active.state == challenge.state else { throw TeamsFailure.invalidAuthorization }
        guard now() < active.expiresAt else { pendingPKCE[challenge.id] = nil; throw TeamsFailure.authorizationExpired }
        let parameters = try TeamsLoopbackCallback.parse(callback, callbackURL: active.callbackURL)
        guard parameters["state"] == active.state else { throw TeamsFailure.invalidAuthorization }
        if parameters["error"] != nil { pendingPKCE[challenge.id] = nil; throw TeamsFailure.authorizationDenied }
        guard let code = parameters["code"], !code.isEmpty, code.utf8.count <= 4096 else { throw TeamsFailure.invalidAuthorization }
        pendingPKCE[challenge.id] = nil // Single-use even if a dispatched exchange has an uncertain outcome.
        exchangingPKCE.insert(challenge.id)
        defer { exchangingPKCE.remove(challenge.id) }
        let response = try await post(configuration: active.configuration, suffix: "token", fields: [
            "client_id": active.configuration.clientID, "grant_type": "authorization_code", "code": code,
            "redirect_uri": active.callbackURL.absoluteString, "code_verifier": active.verifier])
        try Task.checkCancellation()
        guard exchangingPKCE.contains(challenge.id) else { throw TeamsFailure.invalidAuthorization }
        return try tokens(response, old: nil, nonce: active.nonce)
    }

    func beginDevice(configuration: TeamsOAuthConfiguration, capabilities: Set<TeamsCapability>) async throws -> TeamsDeviceChallenge {
        let response = try await post(configuration: configuration, suffix: "devicecode", fields: ["client_id": configuration.clientID, "scope": scopes(capabilities)])
        try Task.checkCancellation()
        struct Wire: Decodable { let device_code: String; let user_code: String; let verification_uri: URL; let expires_in: TimeInterval; let interval: TimeInterval? }
        guard response.status == 200, let wire = try? JSONDecoder().decode(Wire.self, from: response.body),
              !wire.device_code.isEmpty, wire.device_code.utf8.count <= 8192, !wire.user_code.isEmpty,
              wire.verification_uri.scheme == "https", ["microsoft.com", "login.microsoftonline.com"].contains(wire.verification_uri.host?.lowercased() ?? ""),
              wire.verification_uri.user == nil, wire.verification_uri.password == nil,
              wire.verification_uri.port == nil || wire.verification_uri.port == 443,
              wire.expires_in.isFinite, wire.expires_in > 0, wire.expires_in <= 3600,
              (wire.interval ?? 5).isFinite, (wire.interval ?? 5) > 0, (wire.interval ?? 5) <= 3600 else { throw TeamsFailure.invalidResponse }
        let interval = max(5, wire.interval ?? 5)
        let challenge = TeamsDeviceChallenge(id: UUID(), configuration: configuration, deviceCode: wire.device_code, userCode: wire.user_code,
            verificationURL: wire.verification_uri, expiresAt: now().addingTimeInterval(wire.expires_in), interval: interval)
        pendingDevice[challenge.id] = DeviceState(challenge: challenge, interval: interval, next: now().addingTimeInterval(interval))
        return challenge
    }

    func pollDevice(challenge: TeamsDeviceChallenge, now date: Date) async throws -> TeamsDevicePollResult {
        guard var state = pendingDevice[challenge.id] else { throw TeamsFailure.invalidAuthorization }
        guard date < state.challenge.expiresAt else { pendingDevice[challenge.id] = nil; throw TeamsFailure.authorizationExpired }
        guard date >= state.next, !state.inFlight else { return .pending(nextPollAt: state.next, interval: state.interval) }
        state.inFlight = true; pendingDevice[challenge.id] = state
        defer {
            if var current = pendingDevice[challenge.id], current.inFlight {
                current.inFlight = false
                current.next = max(current.next, date.addingTimeInterval(current.interval))
                pendingDevice[challenge.id] = current
            }
        }
        let response: TeamsHTTPResponse
        do { response = try await post(configuration: state.challenge.configuration, suffix: "token", fields: [
            "client_id": state.challenge.configuration.clientID, "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": state.challenge.deviceCode]) }
        catch {
            if pendingDevice[challenge.id] != nil {
                state.inFlight = false; state.next = date.addingTimeInterval(state.interval); pendingDevice[challenge.id] = state
            }
            throw error
        }
        try Task.checkCancellation()
        guard pendingDevice[challenge.id] != nil else { throw TeamsFailure.invalidAuthorization }
        if response.status == 200 {
            let bundle = try tokens(response, old: nil, nonce: nil)
            pendingDevice[challenge.id] = nil
            return .authorized(bundle)
        }
        struct Failure: Decodable { let error: String }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: response.body) else { throw TeamsFailure.invalidResponse }
        if failure.error == "slow_down" || failure.error == "authorization_pending" {
            if failure.error == "slow_down" { state.interval += 5 }
            state.inFlight = false; state.next = date.addingTimeInterval(state.interval); pendingDevice[challenge.id] = state
            return .pending(nextPollAt: state.next, interval: state.interval)
        }
        pendingDevice[challenge.id] = nil
        throw failure.error == "expired_token" ? TeamsFailure.authorizationExpired : TeamsFailure.authorizationDenied
    }

    func refresh(bundle: TeamsTokenBundle, configuration: TeamsOAuthConfiguration) async throws -> TeamsTokenBundle {
        guard let refresh = bundle.refreshToken, !refresh.isEmpty else { throw TeamsFailure.signInRequired }
        let response = try await post(configuration: configuration, suffix: "token", fields: ["client_id": configuration.clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        try Task.checkCancellation()
        return try tokens(response, old: bundle, nonce: nil)
    }

    func verifyIdentity(bundle: TeamsTokenBundle, configuration: TeamsOAuthConfiguration, expected: TeamsPrincipal?) async throws -> TeamsVerifiedSession {
        try configuration.validate()
        guard bundle.expiresAt > now() else { throw TeamsFailure.invalidToken }
        let principal: TeamsPrincipal
        if let token = bundle.idToken {
            principal = try await TeamsOIDC(transport: transport).verify(idToken: token, configuration: configuration,
                nonce: bundle.expectedNonce, expected: expected, now: now())
        } else {
            // A previously verified refresh is accepted only on its pinned tenant authority.
            guard bundle.expectedNonce == nil, let expected, UUID(uuidString: configuration.authority) == UUID(uuidString: expected.tenantID),
                  UUID(uuidString: expected.tenantID) != nil else { throw TeamsFailure.invalidToken }
            principal = expected
        }
        let user = try await TeamsGraphClient(context: TeamsAccountContext(accountID: UUID(), principal: principal), transport: transport)
            .identity(token: bundle.accessToken)
        guard UUID(uuidString: user.id) == UUID(uuidString: principal.userID), UUID(uuidString: user.id) != nil else { throw TeamsFailure.invalidToken }
        try Task.checkCancellation()
        return TeamsVerifiedSession(principal: TeamsPrincipal(tenantID: principal.tenantID, userID: principal.userID, displayName: user.displayName), bundle: bundle)
    }

    func cancelPKCE(id: UUID) { pendingPKCE[id] = nil; exchangingPKCE.remove(id) }
    func cancelDevice(id: UUID) { pendingDevice[id] = nil }

    private func scopes(_ capabilities: Set<TeamsCapability>) -> String {
        capabilities.union([.basicChats]).reduce(into: Set<String>()) { $0.formUnion($1.scopes) }.sorted().joined(separator: " ")
    }

    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TeamsFailure.invalidAuthorization }
        return Data(bytes).teamsBase64URL
    }

    private func post(configuration: TeamsOAuthConfiguration, suffix: String, fields: [String: String]) async throws -> TeamsHTTPResponse {
        var request = URLRequest(url: try configuration.endpoint("oauth2/v2.0/" + suffix), timeoutInterval: 30)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        let response = try await transport.response(to: request)
        guard response.body.count <= 4 * 1024 * 1024 else { throw TeamsFailure.bodyTooLarge }
        return response
    }

    private func tokens(_ response: TeamsHTTPResponse, old: TeamsTokenBundle?, nonce: String?) throws -> TeamsTokenBundle {
        struct Wire: Decodable { let access_token: String; let refresh_token: String?; let id_token: String?; let expires_in: TimeInterval; let token_type: String; let scope: String? }
        guard response.status == 200 else {
            if response.status == 400 || response.status == 401 { throw TeamsFailure.signInRequired }
            throw TeamsFailure.server(status: response.status)
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: response.body), wire.token_type.caseInsensitiveCompare("Bearer") == .orderedSame,
              !wire.access_token.isEmpty, wire.access_token.utf8.count <= 128 * 1024,
              !wire.access_token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              wire.expires_in.isFinite, wire.expires_in > 0, wire.expires_in <= 86400,
              wire.refresh_token.map({ !$0.isEmpty && $0.utf8.count <= 128 * 1024 }) ?? true else { throw TeamsFailure.invalidResponse }
        return TeamsTokenBundle(accessToken: wire.access_token, refreshToken: wire.refresh_token ?? old?.refreshToken,
            idToken: wire.id_token, expiresAt: now().addingTimeInterval(wire.expires_in),
            grantedScopes: wire.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? old?.grantedScopes ?? [], expectedNonce: nonce)
    }
}

/// Parses one complete owned-loopback request. The listener buffers fragments up to the header boundary.
struct TeamsLoopbackCallback {
    static func parse(_ data: Data, callbackURL: URL) throws -> [String: String] {
        guard data.count <= 8192, let text = String(data: data, encoding: .utf8), text.hasSuffix("\r\n\r\n") else { throw TeamsFailure.invalidAuthorization }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", first[1].hasPrefix("/callback?"),
              let components = URLComponents(string: "http://127.0.0.1" + first[1]), components.path == "/callback",
              components.fragment == nil, components.host == "127.0.0.1", components.user == nil else { throw TeamsFailure.invalidAuthorization }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(callbackURL.port ?? 0)" else { throw TeamsFailure.invalidAuthorization }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { throw TeamsFailure.invalidAuthorization }
            query[item.name] = value
        }
        return query
    }
}

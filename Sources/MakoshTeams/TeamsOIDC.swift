import Foundation
import Security

struct TeamsVerifiedSession: Sendable {
    let principal: TeamsPrincipal
    let bundle: TeamsTokenBundle
}

actor TeamsOIDC {
    private let transport: any TeamsHTTPTransport
    init(transport: any TeamsHTTPTransport) { self.transport = transport }

    func verify(idToken: String, configuration: TeamsOAuthConfiguration, nonce: String?, expected: TeamsPrincipal?, now: Date) async throws -> TeamsPrincipal {
        try configuration.validate()
        guard idToken.utf8.count <= 128 * 1024 else { throw TeamsFailure.invalidToken }
        let pieces = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let headerData = Data(teamsBase64URL: String(pieces[0])),
              let claimsData = Data(teamsBase64URL: String(pieces[1])),
              let signature = Data(teamsBase64URL: String(pieces[2])) else { throw TeamsFailure.invalidToken }
        struct Header: Decodable { let alg: String; let kid: String; let crit: [String]? }
        struct Claims: Decodable {
            let ver: String; let aud: String; let iss: String; let tid: String; let oid: String
            let sub: String; let name: String?; let nonce: String?; let exp: TimeInterval; let nbf: TimeInterval; let iat: TimeInterval
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: headerData), header.alg == "RS256",
              !header.kid.isEmpty, header.kid.utf8.count <= 256, header.crit?.isEmpty ?? true,
              let claims = try? JSONDecoder().decode(Claims.self, from: claimsData), claims.ver == "2.0",
              claims.aud == configuration.clientID, let tenant = UUID(uuidString: claims.tid), let user = UUID(uuidString: claims.oid),
              tenant.uuidString.lowercased() != "9188040d-6c67-4c5b-b112-36a304b66dad",
              configuration.authority == "organizations" || UUID(uuidString: configuration.authority) == tenant,
              !claims.sub.isEmpty, claims.sub.utf8.count <= 1024,
              claims.exp.isFinite, claims.nbf.isFinite, claims.iat.isFinite, now.timeIntervalSince1970.isFinite,
              claims.exp > now.timeIntervalSince1970, claims.nbf <= now.timeIntervalSince1970 + 60,
              claims.iat <= now.timeIntervalSince1970 + 60, claims.nbf <= claims.exp, claims.iat < claims.exp,
              nonce.map({ claims.nonce == $0 }) ?? true,
              claims.iss == "https://login.microsoftonline.com/\(claims.tid)/v2.0" else { throw TeamsFailure.invalidToken }
        let principal = TeamsPrincipal(tenantID: tenant.uuidString.lowercased(), userID: user.uuidString.lowercased(), displayName: claims.name ?? "")
        guard expected.map({ $0 == principal }) ?? true else { throw TeamsFailure.invalidToken }
        struct Metadata: Decodable { let issuer: String; let jwks_uri: URL }
        let metadata = try JSONDecoder().decode(Metadata.self, from: await get(configuration.endpoint("v2.0/.well-known/openid-configuration")))
        guard metadata.issuer.replacingOccurrences(of: "{tenantid}", with: claims.tid) == claims.iss,
              acceptedKeysURL(metadata.jwks_uri, tenant: tenant) else { throw TeamsFailure.invalidToken }
        struct Key: Decodable { let kty: String; let use: String?; let alg: String?; let kid: String; let n: String; let e: String; let issuer: String }
        struct Keys: Decodable { let keys: [Key] }
        let keys = try JSONDecoder().decode(Keys.self, from: await get(metadata.jwks_uri))
        let matching = keys.keys.filter { $0.kid == header.kid }
        guard matching.count == 1, let jwk = matching.first, jwk.kty == "RSA", jwk.use == "sig", jwk.alg == nil || jwk.alg == "RS256",
              jwk.issuer.replacingOccurrences(of: "{tenantid}", with: claims.tid) == claims.iss,
              let modulus = Data(teamsBase64URL: jwk.n), (256...1024).contains(modulus.count), modulus.first.map({ $0 >= 0x80 }) == true,
              let exponent = Data(teamsBase64URL: jwk.e), (1...8).contains(exponent.count), exponent.first != 0 else { throw TeamsFailure.invalidToken }
        let der = Self.der(0x30, Self.integer(modulus) + Self.integer(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                       kSecAttrKeySizeInBits as String: modulus.count * 8]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((pieces[0] + "." + pieces[1]).utf8) as CFData, signature as CFData, nil) else {
            throw TeamsFailure.invalidToken
        }
        try Task.checkCancellation()
        return principal
    }

    private func get(_ url: URL) async throws -> Data {
        let response = try await transport.response(to: URLRequest(url: url, timeoutInterval: 30))
        guard response.status == 200, response.body.count <= 4 * 1024 * 1024 else { throw TeamsFailure.invalidToken }
        return response.body
    }

    private func acceptedKeysURL(_ url: URL, tenant: UUID) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https",
              components.host == "login.microsoftonline.com", components.port == nil || components.port == 443,
              components.user == nil, components.password == nil, components.fragment == nil, components.query == nil else { return false }
        let paths = ["common", "organizations", tenant.uuidString.lowercased()].map { "/\($0)/discovery/v2.0/keys" }
        return paths.contains(components.percentEncodedPath)
    }

    private static func integer(_ value: Data) -> Data {
        der(0x02, value.first.map({ $0 >= 0x80 }) == true ? Data([0]) + value : value)
    }
    private static func der(_ tag: UInt8, _ value: Data) -> Data {
        var length = value.count
        var bytes: [UInt8] = []
        if length < 128 { bytes = [UInt8(length)] }
        else {
            while length > 0 { bytes.insert(UInt8(length & 0xff), at: 0); length >>= 8 }
            bytes.insert(0x80 | UInt8(bytes.count), at: 0)
        }
        return Data([tag] + bytes) + value
    }
}

import XCTest
import Security
@testable import MakoshTeams

struct TeamsRSAFixture {
    let key: SecKey
    let jwks: Data
    init(issuer: String = "https://login.microsoftonline.com/{tenantid}/v2.0") throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // PKCS#1 SEQUENCE(INTEGER modulus, INTEGER exponent), generated independently by Security.
        var cursor = 0
        func field() throws -> Data {
            guard cursor + 2 <= der.count else { throw TeamsFailure.invalidResponse }
            cursor += 1
            var length = Int(der[cursor]); cursor += 1
            if length & 0x80 != 0 {
                let bytes = length & 0x7f; length = 0
                guard cursor + bytes <= der.count else { throw TeamsFailure.invalidResponse }
                for _ in 0..<bytes { length = (length << 8) | Int(der[cursor]); cursor += 1 }
            }
            guard cursor + length <= der.count else { throw TeamsFailure.invalidResponse }
            let value = der.subdata(in: cursor..<cursor + length); cursor += length
            return value
        }
        cursor = 1
        let initial = Int(der[cursor]); cursor += 1
        if initial & 0x80 != 0 { cursor += initial & 0x7f }
        var modulus = try field()
        while modulus.first == 0 { modulus.removeFirst() }
        let exponent = try field()
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "use": "sig", "alg": "RS256", "kid": "synthetic-key", "n": modulus.teamsBase64URL, "e": exponent.teamsBase64URL, "issuer": issuer]]])
    }
    func token(claims: [String: Any], algorithm: String = "RS256") throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "synthetic-key", "typ": "JWT"]).teamsBase64URL
        let body = try JSONSerialization.data(withJSONObject: claims).teamsBase64URL
        let message = header + "." + body
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)) as Data
        return message + "." + signature.teamsBase64URL
    }
}

@MainActor
final class TeamsOIDCTests: XCTestCase {
    let configuration = TeamsOAuthConfiguration(clientID: "44444444-4444-4444-8444-444444444444", authority: "organizations")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var claims: [String: Any] {
        ["ver": "2.0", "aud": configuration.clientID, "iss": "https://login.microsoftonline.com/11111111-1111-4111-8111-111111111111/v2.0",
         "tid": "11111111-1111-4111-8111-111111111111", "oid": "22222222-2222-4222-8222-222222222222", "sub": "test-subject",
         "name": "Test User", "nonce": "expected", "iat": 1_799_999_990, "nbf": 1_799_999_990, "exp": 1_800_003_600]
    }
    func http(_ fixture: TeamsRSAFixture) -> TeamsScriptedHTTP {
        TeamsScriptedHTTP([teamsJSON("{\"issuer\":\"https://login.microsoftonline.com/{tenantid}/v2.0\",\"jwks_uri\":\"https://login.microsoftonline.com/common/discovery/v2.0/keys\"}"),
            TeamsHTTPResponse(status: 200, headers: [:], body: fixture.jwks),
            teamsJSON("{\"id\":\"22222222-2222-4222-8222-222222222222\",\"displayName\":\"Test User\",\"mail\":\"test@example.invalid\"}")])
    }
    // All identity trust comes from the verified ID-token signature and authority, never JWT-shaped access-token claims.
    func testOIDCRejectsWrongSignatureAudienceIssuerNonceAndTenant() async throws {
        let fixture = try TeamsRSAFixture()
        let verifier = TeamsOIDC(transport: http(fixture))
        let valid = try await verifier.verify(idToken: fixture.token(claims: claims), configuration: configuration,
            nonce: "expected", expected: teamsTestContext.principal, now: now)
        XCTAssertEqual(valid, teamsTestContext.principal)
        var mutations: [[String: Any]] = []
        for (key, value) in [("aud", "other-client"), ("iss", "https://example.invalid/v2.0"), ("nonce", "other"),
                             ("tid", "55555555-5555-4555-8555-555555555555"), ("oid", "66666666-6666-4666-8666-666666666666")] {
            var changed = claims; changed[key] = value; mutations.append(changed)
        }
        var expired = claims; expired["exp"] = 1_799_999_000; mutations.append(expired)
        for changed in mutations {
            do {
                _ = try await TeamsOIDC(transport: http(fixture)).verify(idToken: fixture.token(claims: changed), configuration: configuration,
                    nonce: "expected", expected: teamsTestContext.principal, now: now)
                XCTFail("Invalid identity accepted")
            } catch let error as TeamsFailure { XCTAssertEqual(error, .invalidToken) }
        }
        let different = try TeamsRSAFixture()
        for token in [try different.token(claims: claims), try fixture.token(claims: claims, algorithm: "none")] {
            do {
                _ = try await TeamsOIDC(transport: http(fixture)).verify(idToken: token, configuration: configuration,
                    nonce: "expected", expected: nil, now: now)
                XCTFail("Invalid signature accepted")
            } catch let error as TeamsFailure { XCTAssertEqual(error, .invalidToken) }
        }
    }

    func testOpaqueAccessTokenIsNotParsedAsIdentity() async throws {
        let fixture = try TeamsRSAFixture()
        let client = TeamsOAuthClient(transport: http(fixture), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let bundle = TeamsTokenBundle(accessToken: "opaque-not-a-jwt", refreshToken: "r", idToken: try fixture.token(claims: claims),
            expiresAt: now.addingTimeInterval(3600), grantedScopes: ["User.Read"], expectedNonce: "expected")
        let verified = try await client.verifyIdentity(bundle: bundle, configuration: configuration, expected: nil)
        XCTAssertEqual(verified.principal, teamsTestContext.principal)
        XCTAssertEqual(verified.bundle.accessToken, "opaque-not-a-jwt")
    }

    func testForeignSigningKeyIssuerAndUntrustedKeyURLAreRejected() async throws {
        let fixture = try TeamsRSAFixture(issuer: "https://login.microsoftonline.com/55555555-5555-4555-8555-555555555555/v2.0")
        do {
            _ = try await TeamsOIDC(transport: http(fixture)).verify(idToken: fixture.token(claims: claims), configuration: configuration,
                nonce: "expected", expected: nil, now: now)
            XCTFail("Foreign key issuer trusted")
        } catch let error as TeamsFailure { XCTAssertEqual(error, .invalidToken) }
        let hostile = TeamsScriptedHTTP([teamsJSON("{\"issuer\":\"https://login.microsoftonline.com/{tenantid}/v2.0\",\"jwks_uri\":\"https://example.invalid/keys\"}")])
        do {
            _ = try await TeamsOIDC(transport: hostile).verify(idToken: fixture.token(claims: claims), configuration: configuration,
                nonce: "expected", expected: nil, now: now)
            XCTFail("Untrusted key endpoint used")
        } catch let error as TeamsFailure { XCTAssertEqual(error, .invalidToken) }
        let sent = await hostile.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent.first?.value(forHTTPHeaderField: "Authorization"))
    }
}

import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshPersons

final class GoogleContactsAdapterTests: XCTestCase {
    private let grant = GoogleGrant(
        subject: "10001", email: "me@gmail.test", scopes: ["https://www.googleapis.com/auth/contacts"], refreshToken: "rt")
    private let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private func adapter(_ routes: @escaping (URLRequest) -> StubURLProtocol.Reply) -> GoogleContactsAdapter {
        StubURLProtocol.install { request in
            if request.url?.host == "oauth2.googleapis.com" { return .init(body: Data(#"{"access_token":"at","expires_in":3600}"#.utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at")
            return routes(request)
        }
        let http = StubURLProtocol.http()
        let oauth = GoogleOAuth(
            client: GoogleOAuthClient(clientID: "c", clientSecret: "s"), http: http.service, scopes: GoogleOAuth.contactsScopes,
            openBrowser: { _ in })
        return GoogleContactsAdapter(grant: grant, oauth: oauth, http: http)
    }
    private func json(_ text: String, status: Int = 200) -> StubURLProtocol.Reply {
        .init(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }
    private var apiRequests: [URLRequest] { StubURLProtocol.requests.filter { $0.url?.host == "people.googleapis.com" } }
    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    static let page = """
        {"connections":[
          {"resourceName":"people/c1","etag":"e1","names":[{"displayName":"Иванов Пётр","givenName":"Пётр","familyName":"Иванов"}],
           "emailAddresses":[{"value":"ivanov@sidorov.ru"}],"phoneNumbers":[{"value":"+7 916 000-00-00"}],
           "organizations":[{"name":"ИП Сидоров","title":"Менеджер"}],
           "clientData":[{"key":"makosh-person","value":"11111111-2222-4333-8444-555555555555"}]},
          {"resourceName":"people/c2","etag":"e2","names":[{"displayName":"Анна"}],"emailAddresses":[{"value":"anna@gmail.com"}]},
          {"resourceName":"people/c3","etag":"e3","names":[{"displayName":"ООО Ромашка"}],
           "clientData":[{"key":"makosh-kind","value":"organization"}]},
          {"resourceName":"people/gone","metadata":{"deleted":true}}
        ],"nextSyncToken":"sync-2"}
        """

    func testGoogleListMapsCardsAndMarker() async throws {
        let adapter = adapter { request in
            XCTAssertEqual(request.url?.path, "/v1/people/me/connections")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "requestSyncToken" }?.value, "true")
            XCTAssertTrue(query.first { $0.name == "personFields" }?.value?.contains("clientData") ?? false)
            XCTAssertNil(query.first { $0.name == "syncToken" })
            return self.json(Self.page)
        }
        let changes = try await adapter.changes(cursor: nil)
        XCTAssertTrue(changes.full)
        XCTAssertEqual(changes.cards.map(\.externalID), ["people/c1", "people/c2", "people/c3"])
        XCTAssertEqual(changes.cards[0].makoshID, id)
        XCTAssertEqual(changes.cards[0].imported.givenName, "Пётр")
        XCTAssertEqual(changes.cards[0].imported.organization, "ИП Сидоров")
        XCTAssertEqual(changes.cards[0].imported.jobTitle, "Менеджер")
        XCTAssertEqual(changes.cards[0].imported.phones, ["+7 916 000-00-00"])
        XCTAssertEqual(changes.cards[1].makoshID, nil)
        XCTAssertEqual(changes.cards[2].kind, .organization)
        XCTAssertEqual(changes.removedExternalIDs, ["people/gone"])
        XCTAssertEqual(changes.cursor, Data("sync-2".utf8))
    }

    func testGoogle410ForcesFullRead() async throws {
        let adapter = adapter { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if query.contains(where: { $0.name == "syncToken" }) { return self.json(#"{"error":{"code":410}}"#, status: 410) }
            return self.json(Self.page)
        }
        let changes = try await adapter.changes(cursor: Data("stale".utf8))
        XCTAssertTrue(changes.full)
        XCTAssertEqual(apiRequests.count, 2)
        XCTAssertEqual(changes.cards.count, 3)
    }

    func testGoogleCreateSendsClientData() async throws {
        let adapter = adapter { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/people:createContact")
            let body = self.body(request)
            let client = body["clientData"] as? [[String: String]] ?? []
            XCTAssertTrue(client.contains { $0["key"] == "makosh-person" && $0["value"] == self.id.uuidString })
            XCTAssertEqual((body["names"] as? [[String: String]])?.first?["givenName"], "Анна")
            XCTAssertEqual((body["emailAddresses"] as? [[String: String]])?.first?["value"], "a@x.ru")
            return self.json(#"{"resourceName":"people/new","etag":"e-new"}"#)
        }
        let card = PersonCard(
            makoshID: id, kind: .person, displayName: "Анна", givenName: "Анна", familyName: "", middleName: "", phones: [],
            emails: ["a@x.ru"],
            organization: "", jobTitle: "")
        let ref = try await adapter.create(card)
        XCTAssertEqual(ref, RemoteCardRef(externalID: "people/new", etag: "e-new"))
    }

    func testGoogleUpdateAndDeleteAndFind() async throws {
        let adapter = adapter { request in
            switch (request.httpMethod, request.url?.path) {
            case ("PATCH", "/v1/people/c1:updateContact"):
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                XCTAssertTrue(query.first { $0.name == "updatePersonFields" }?.value?.contains("names") ?? false)
                XCTAssertEqual(self.body(request)["etag"] as? String, "e1")
                return self.json(#"{"resourceName":"people/c1","etag":"e1b"}"#)
            case ("DELETE", "/v1/people/c1:deleteContact"): return self.json("{}")
            case ("GET", "/v1/people/me/connections"): return self.json(Self.page)
            default: return .init(status: 500)
            }
        }
        let card = PersonCard(
            makoshID: id, kind: .organization, displayName: "ООО Ромашка", givenName: "", familyName: "", middleName: "", phones: [],
            emails: [], organization: "", jobTitle: "")
        let ref = try await adapter.update(externalID: "people/c1", etag: "e1", card: card)
        XCTAssertEqual(ref.etag, "e1b")
        let patch = try XCTUnwrap(apiRequests.first { $0.httpMethod == "PATCH" })
        let client = body(patch)["clientData"] as? [[String: String]] ?? []
        XCTAssertTrue(client.contains { $0["key"] == "makosh-kind" && $0["value"] == "organization" })
        XCTAssertEqual((body(patch)["organizations"] as? [[String: String]])?.first?["name"], "ООО Ромашка")
        try await adapter.delete(externalID: "people/c1", etag: "e1b")
        let found = try await adapter.find(makoshID: id)
        XCTAssertEqual(found, RemoteCardRef(externalID: "people/c1", etag: "e1"))
        let missing = try await adapter.find(makoshID: UUID())
        XCTAssertNil(missing)
    }

    func testGoogle401IsSignInRequired() async {
        let adapter = adapter { _ in self.json(#"{"error":{"code":401,"message":"secret detail"}}"#, status: 401) }
        do {
            _ = try await adapter.changes(cursor: nil)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? PersonsFailure, .signInRequired)
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
    }

    func testRevokedGrantIsSignInRequired() async {
        StubURLProtocol.install { request in
            if request.url?.host == "oauth2.googleapis.com" {
                return .init(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return .init(status: 500)
        }
        let http = StubURLProtocol.http()
        let oauth = GoogleOAuth(
            client: GoogleOAuthClient(clientID: "c", clientSecret: "s"), http: http.service, scopes: GoogleOAuth.contactsScopes,
            openBrowser: { _ in })
        let adapter = GoogleContactsAdapter(grant: grant, oauth: oauth, http: http)
        do {
            _ = try await adapter.changes(cursor: nil)
            XCTFail()
        } catch { XCTAssertEqual(error as? PersonsFailure, .signInRequired) }
    }
}

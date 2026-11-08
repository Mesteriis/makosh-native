import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class CardDAVAdapterTests: XCTestCase {
    private let server = URL(string: "https://carddav.yandex.ru")!
    private let collection = URL(string: "https://carddav.yandex.ru/addressbook/me/addressbook/")!
    private let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private func adapter() -> CardDAVAdapter {
        CardDAVAdapter(collection: collection, login: "me@ya.ru", password: "app-password", http: StubURLProtocol.http())
    }
    private func xml(_ body: String, status: Int = 207) -> StubURLProtocol.Reply {
        .init(status: status, headers: ["Content-Type": "application/xml"], body: Data(body.utf8))
    }
    private func card(_ name: String, uid: String, marker: UUID? = nil) -> String {
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:\(uid)\r\nFN:\(name)\r\nN:;\(name);;;\r\nEMAIL:\(uid)@x.ru\r\n"
            + (marker.map { "X-MAKOSH-PERSON:\($0.uuidString)\r\n" } ?? "") + "END:VCARD\r\n"
    }
    private func multistatus(_ responses: String, token: String? = nil) -> String {
        #"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">"# + responses
            + (token.map { "<d:sync-token>\($0)</d:sync-token>" } ?? "") + "</d:multistatus>"
    }
    private func response(_ href: String, etag: String, data: String? = nil, status: String = "HTTP/1.1 200 OK") -> String {
        "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:getetag>\"\(etag)\"</d:getetag>"
            + (data.map { "<card:address-data><![CDATA[\($0)]]></card:address-data>" } ?? "")
            + "</d:prop><d:status>\(status)</d:status></d:propstat></d:response>"
    }

    func testDiscoveryFindsAddressBooks() async throws {
        StubURLProtocol.install { request in
            switch (request.httpMethod, request.url?.path) {
            case ("PROPFIND", "/.well-known/carddav"):
                return self.xml(
                    self.multistatus(
                        "<d:response><d:href>/</d:href><d:propstat><d:prop><d:current-user-principal><d:href>/principals/users/me/</d:href></d:current-user-principal></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                    ))
            case ("PROPFIND", "/principals/users/me"):
                return self.xml(
                    self.multistatus(
                        "<d:response><d:href>/principals/users/me/</d:href><d:propstat><d:prop><card:addressbook-home-set><d:href>/addressbook/me/</d:href></card:addressbook-home-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                    ))
            case ("PROPFIND", "/addressbook/me"):
                return self.xml(
                    self.multistatus(
                        "<d:response><d:href>/addressbook/me/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                            + "<d:response><d:href>/addressbook/me/addressbook/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><card:addressbook/></d:resourcetype><d:displayname>Контакты</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                    ))
            default:
                XCTFail("unexpected \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
                return .init(status: 500)
            }
        }
        let books = try await CardDAVAdapter.discover(server: server, login: "me@ya.ru", password: "p", http: StubURLProtocol.http())
        XCTAssertEqual(books.map(\.name), ["Контакты"])
        XCTAssertEqual(books.first?.url, collection)
        XCTAssertEqual(
            StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Basic " + Data("me@ya.ru:p".utf8).base64EncodedString())
    }

    func testSyncCollectionUpdatesCursor() async throws {
        StubURLProtocol.install { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertEqual(request.httpMethod, "REPORT")
            XCTAssertTrue(body.contains("sync-collection"))
            if body.contains("<d:sync-token></d:sync-token>") {
                return self.xml(
                    self.multistatus(
                        self.response("/addressbook/me/addressbook/a.vcf", etag: "1", data: self.card("Анна", uid: "a", marker: self.id))
                            + self.response("/addressbook/me/addressbook/b.vcf", etag: "2", data: self.card("Борис", uid: "b")),
                        token: "t-1"))
            }
            XCTAssertTrue(body.contains("<d:sync-token>t-1</d:sync-token>"))
            return self.xml(
                self.multistatus(
                    self.response("/addressbook/me/addressbook/b.vcf", etag: "3", data: self.card("Борис Б.", uid: "b"))
                        + "<d:response><d:href>/addressbook/me/addressbook/a.vcf</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>",
                    token: "t-2"))
        }
        let first = try await adapter().changes(cursor: nil)
        XCTAssertTrue(first.full)
        XCTAssertEqual(first.cards.map(\.imported.displayName), ["Анна", "Борис"])
        XCTAssertEqual(first.cards.first?.makoshID, id)
        XCTAssertEqual(first.cards.first?.externalID, collection.absoluteString + "a.vcf")
        XCTAssertEqual(first.cards.first?.etag, "\"1\"")
        let second = try await adapter().changes(cursor: first.cursor)
        XCTAssertFalse(second.full)
        XCTAssertEqual(second.cards.map(\.imported.displayName), ["Борис Б."])
        XCTAssertEqual(second.removedExternalIDs, [collection.absoluteString + "a.vcf"])
        XCTAssertNotEqual(second.cursor, first.cursor)
    }

    func testFallbackToEtagComparison() async throws {
        StubURLProtocol.install { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("sync-collection") { return .init(status: 403) }
            if body.contains("addressbook-query") {
                return self.xml(
                    self.multistatus(
                        self.response("/addressbook/me/addressbook/a.vcf", etag: "1")
                            + self.response("/addressbook/me/addressbook/b.vcf", etag: "2")))
            }
            if body.contains("addressbook-multiget") {
                XCTAssertTrue(body.contains("<d:href>/addressbook/me/addressbook/a.vcf</d:href>"))
                return self.xml(
                    self.multistatus(
                        self.response("/addressbook/me/addressbook/a.vcf", etag: "1", data: self.card("Анна", uid: "a"))
                            + self.response("/addressbook/me/addressbook/b.vcf", etag: "2", data: self.card("Борис", uid: "b"))))
            }
            return .init(status: 500)
        }
        let first = try await adapter().changes(cursor: nil)
        XCTAssertTrue(first.full)
        XCTAssertEqual(first.cards.map(\.imported.displayName), ["Анна", "Борис"])
        StubURLProtocol.install { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("sync-collection") { return .init(status: 403) }
            if body.contains("addressbook-query") {
                return self.xml(self.multistatus(self.response("/addressbook/me/addressbook/b.vcf", etag: "3")))
            }
            XCTAssertFalse(body.contains("a.vcf"), "only the changed card is fetched")
            return self.xml(
                self.multistatus(self.response("/addressbook/me/addressbook/b.vcf", etag: "3", data: self.card("Борис Б.", uid: "b"))))
        }
        let second = try await adapter().changes(cursor: first.cursor)
        XCTAssertEqual(second.cards.map(\.imported.displayName), ["Борис Б."])
        XCTAssertEqual(second.removedExternalIDs, [collection.absoluteString + "a.vcf"])
    }

    func testCreateUsesIfNoneMatch() async throws {
        StubURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/vcard; charset=utf-8")
            XCTAssertTrue(request.url!.path.hasSuffix(".vcf"))
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains("X-MAKOSH-PERSON:" + self.id.uuidString))
            return .init(status: 201, headers: ["ETag": "\"new\""])
        }
        let card = PersonCard(
            makoshID: id, kind: .person, displayName: "Анна", givenName: "Анна", familyName: "", middleName: "", phones: [],
            emails: ["a@x.ru"],
            organization: "", jobTitle: "")
        let ref = try await adapter().create(card)
        XCTAssertEqual(ref.etag, "\"new\"")
        XCTAssertTrue(ref.externalID.hasPrefix(collection.absoluteString))
    }

    func testUpdateSendsIfMatchAnd412IsPrecondition() async throws {
        StubURLProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"1\"")
            return .init(status: 412)
        }
        let card = PersonCard(
            makoshID: id, kind: .person, displayName: "Анна", givenName: "Анна", familyName: "", middleName: "", phones: [], emails: [],
            organization: "", jobTitle: "")
        do {
            _ = try await adapter().update(externalID: collection.absoluteString + "a.vcf", etag: "\"1\"", card: card)
            XCTFail("412 must surface as a precondition failure")
        } catch { XCTAssertEqual(error as? PersonsFailure, .preconditionFailed) }
        StubURLProtocol.install { _ in .init(status: 404) }
        try await adapter().delete(externalID: collection.absoluteString + "a.vcf", etag: "\"1\"")
    }

    func testFindByMarkerUsesPropFilter() async throws {
        StubURLProtocol.install { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains(#"prop-filter name="X-MAKOSH-PERSON""#))
            XCTAssertTrue(body.contains(self.id.uuidString))
            return self.xml(
                self.multistatus(
                    self.response("/addressbook/me/addressbook/a.vcf", etag: "7", data: self.card("Анна", uid: "a", marker: self.id))))
        }
        let found = try await adapter().find(makoshID: id)
        XCTAssertEqual(found, RemoteCardRef(externalID: collection.absoluteString + "a.vcf", etag: "\"7\""))
        StubURLProtocol.install { _ in self.xml(self.multistatus("")) }
        let missing = try await adapter().find(makoshID: id)
        XCTAssertNil(missing)
        let capabilities = await adapter().capabilities
        XCTAssertTrue(capabilities.supportsMarker)
        XCTAssertTrue(capabilities.acceptsOrganizations)
    }

    func testErrorsCarryNoBodyOrURL() async {
        StubURLProtocol.install { _ in .init(status: 403, body: Data("secret body token=abc".utf8)) }
        do {
            _ = try await adapter().changes(cursor: nil)
            XCTFail()
        } catch {
            let text = String(describing: error)
            XCTAssertFalse(text.contains("secret"))
            XCTAssertFalse(text.contains("yandex"))
            XCTAssertEqual(error as? PersonsFailure, .rejected(code: 403, stage: "query"))
        }
    }
}

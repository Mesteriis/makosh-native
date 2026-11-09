import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshPersons

final class PersonsServiceConnectTests: XCTestCase {
    private var db: PersonsTestDatabase!
    private var store: PersonsStore!
    private var vault: PersonsCredentialVault!
    private var service: PersonsService!

    override func setUp() async throws {
        db = try personsDatabase()
        store = try await personsStore(db)
        vault = PersonsCredentialVault(access: .memory())
        let http = StubURLProtocol.http()
        service = PersonsService(
            persons: try db.persons(), store: store, vault: vault,
            adapterFactory: { book, vault in
                guard let collection = book.caldavServer, let login = book.caldavLogin,
                    let password = try await vault.password(bookID: book.id)
                else { throw PersonsFailure.signInRequired }
                return CardDAVAdapter(collection: collection, login: login, password: password, http: http)
            }, google: nil, grants: GoogleGrantVault(access: .memory()), http: http)
        try await service.open()
    }

    private func xml(_ body: String) -> StubURLProtocol.Reply {
        .init(status: 207, headers: ["Content-Type": "application/xml"], body: Data(body.utf8))
    }
    private func multistatus(_ responses: String, token: String? = nil) -> String {
        #"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">"# + responses
            + (token.map { "<d:sync-token>\($0)</d:sync-token>" } ?? "") + "</d:multistatus>"
    }

    func testConnectCardDAVDiscoversTheCollectionAndKeepsThePasswordInTheVault() async throws {
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
                        "<d:response><d:href>/addressbook/me/addressbook/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><card:addressbook/></d:resourcetype><d:displayname>Контакты</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                    ))
            case ("REPORT", _):
                return self.xml(self.multistatus("", token: "t-1"))
            default:
                XCTFail("unexpected \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
                return .init(status: 500)
            }
        }
        let book = try await service.connectCardDAV(
            name: "Яндекс", server: URL(string: "https://carddav.yandex.ru")!, login: "me@ya.ru", password: "app-password")
        XCTAssertEqual(book.kind, .carddav)
        XCTAssertEqual(book.caldavServer, URL(string: "https://carddav.yandex.ru/addressbook/me/addressbook/"))
        XCTAssertEqual(book.caldavLogin, "me@ya.ru")
        XCTAssertEqual(book.accountID, "me@ya.ru@carddav.yandex.ru")
        XCTAssertEqual(book.state, .connected)
        let password = try await vault.password(bookID: book.id)
        XCTAssertEqual(password, "app-password")
        let saved = try await store.book(id: book.id)
        XCTAssertNotNil(saved?.cursor, "the first read ran")
        let again = try await service.connectCardDAV(
            name: "Яндекс", server: URL(string: "https://carddav.yandex.ru")!, login: "me@ya.ru", password: "new-password")
        XCTAssertEqual(again.id, book.id, "the same login on the same server is one book")
        let rotated = try await vault.password(bookID: book.id)
        XCTAssertEqual(rotated, "new-password")
    }

    func testConnectCardDAVWithoutAnAddressBookFails() async throws {
        StubURLProtocol.install { _ in .init(status: 401) }
        do {
            _ = try await service.connectCardDAV(
                name: "x", server: URL(string: "https://carddav.example.test")!, login: "me", password: "p")
            XCTFail("401 is a sign-in failure")
        } catch { XCTAssertEqual(error as? PersonsFailure, .signInRequired) }
        let books = try await store.books()
        XCTAssertTrue(books.isEmpty, "nothing is saved until discovery succeeds")
    }

    func testConnectGoogleWithoutAClientFails() async throws {
        do {
            _ = try await service.connectGoogle(loginHint: nil)
            XCTFail()
        } catch { XCTAssertEqual(error as? PersonsFailure, .signInRequired) }
    }
}

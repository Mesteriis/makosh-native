import CPostgres
import Foundation
import MakoshCore
import MakoshPersons
import XCTest

@testable import MakoshApp

@MainActor
final class PersonsSettingsModelTests: XCTestCase {
    func testCardDAVHintsByDomainAndHost() throws {
        let yandex = try XCTUnwrap(CardDAVHints.suggestion(email: "me@yandex.ru", imapHost: "imap.yandex.ru"))
        XCTAssertEqual(yandex.server, URL(string: "https://carddav.yandex.ru"))
        XCTAssertEqual(yandex.login, "me@yandex.ru")
        let icloud = try XCTUnwrap(CardDAVHints.suggestion(email: "Me@iCloud.com", imapHost: "imap.mail.me.com"))
        XCTAssertEqual(icloud.server, URL(string: "https://contacts.icloud.com"))
        XCTAssertEqual(icloud.login, "Me@iCloud.com")
        let fastmail = try XCTUnwrap(CardDAVHints.suggestion(email: "me@own-domain.test", imapHost: "imap.fastmail.com"))
        XCTAssertEqual(fastmail.server, URL(string: "https://carddav.fastmail.com"))
        let me = try XCTUnwrap(CardDAVHints.suggestion(email: "me@me.com", imapHost: "imap.example.test"))
        XCTAssertEqual(me.server, URL(string: "https://contacts.icloud.com"))
        XCTAssertNil(CardDAVHints.suggestion(email: "me@example.test", imapHost: "imap.example.test"))
    }

    func testICloudDoubleWriteWarning() {
        let mac = PersonBook(kind: .macContacts, name: "Контакты macOS", accountID: "mac")
        let icloud = PersonBook(
            kind: .carddav, name: "iCloud", accountID: "me@icloud.com",
            caldavServer: URL(string: "https://contacts.icloud.com/123/carddavhome/card/"))
        let yandex = PersonBook(
            kind: .carddav, name: "Яндекс", accountID: "me@ya.ru", caldavServer: URL(string: "https://carddav.yandex.ru/addressbook/"))
        XCTAssertTrue(PersonsSettingsRules.warnsDoubleICloud(books: [mac, icloud]))
        XCTAssertFalse(PersonsSettingsRules.warnsDoubleICloud(books: [mac, yandex]))
        XCTAssertFalse(PersonsSettingsRules.warnsDoubleICloud(books: [icloud]))
        var readOnlyMac = mac
        readOnlyMac.acceptsAddressBook = false
        XCTAssertFalse(PersonsSettingsRules.warnsDoubleICloud(books: [readOnlyMac, icloud]), "only two writable books double the writes")
        var disabledICloud = icloud
        disabledICloud.state = .disabled
        XCTAssertFalse(PersonsSettingsRules.warnsDoubleICloud(books: [mac, disabledICloud]))
    }

    func testPollIntervalChoicesContainTheDefault() {
        XCTAssertTrue(PersonsSettingsRules.pollIntervals.contains(PersonsPreferences().pollIntervalSeconds))
    }

    func testSourceFlagOffClearsFlagsThroughService() async throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !dsn.isEmpty else {
            throw XCTSkip("MAKOSH_TEST_DATABASE_URL is required")
        }
        let schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defer { Self.dropSchema(schema, dsn: dsn) }
        let configuration = PersonWorkspaceConfiguration(connectionString: dsn, schema: schema)
        let worker = PersonWorkspaceWorker(configuration: configuration)
        _ = try await worker.open()
        let card = RemoteCard(
            externalID: "c1", etag: "1", makoshID: nil,
            imported: ImportedPerson(externalID: "c1", displayName: "Анна", emails: ["anna@x.ru"]),
            kind: .person)
        let host = PersonsHost(synthetic: ["yandex": PersonSyntheticBook(cards: [card])])
        await host.configure(configuration: configuration, worker: worker) { service in
            let book = try await service.connectSynthetic(name: "Яндекс", accountID: "yandex", isAddressBookSource: true)
            _ = try await service.readBook(id: book.id)
        }
        let model = try XCTUnwrap(host.model)
        let service = try XCTUnwrap(host.service)
        let book = try XCTUnwrap(model.snapshot?.books.first)
        XCTAssertTrue(book.isAddressBookSource)
        let flagged = try await service.persons.persons()
        XCTAssertEqual(flagged.map(\.addressBook), [true])
        await model.setBookOptions(id: book.id, isAddressBookSource: false)
        XCTAssertNil(model.error)
        let cleared = try await service.persons.persons()
        XCTAssertEqual(cleared.map(\.addressBook), [false])
        XCTAssertEqual(model.snapshot?.books.first?.isAddressBookSource, false)
    }

    static func dropSchema(_ schema: String, dsn: String) {
        guard schema.hasPrefix("makosh_test_"), let db = PQconnectdb(dsn), PQstatus(db) == CONNECTION_OK else { return }
        defer { PQfinish(db) }
        if let result = PQexec(db, "DROP SCHEMA IF EXISTS \"\(schema)\" CASCADE") { PQclear(result) }
    }
}

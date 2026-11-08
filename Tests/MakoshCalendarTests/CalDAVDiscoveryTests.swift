import Foundation
import XCTest
@testable import MakoshCalendar

final class CalDAVDiscoveryTests: XCTestCase {
    private let server = URL(string: "https://caldav.test")!

    private func install(schedule: Bool = true) {
        StubURLProtocol.install { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("me@ya.test:app-pass".utf8).base64EncodedString())
            switch (request.httpMethod, request.url?.path) {
            case ("PROPFIND", "/.well-known/caldav"): return .init(status: 207, body: CalDAVFixture.principal)
            case ("PROPFIND", "/principals/me"), ("PROPFIND", "/principals/me/"): return .init(status: 207, body: CalDAVFixture.home)
            case ("OPTIONS", _):
                return .init(
                    status: 200, headers: ["DAV": schedule ? "1, 2, calendar-access, calendar-auto-schedule" : "1, 2, calendar-access"])
            case ("PROPFIND", "/calendars/me"), ("PROPFIND", "/calendars/me/"): return .init(status: 207, body: CalDAVFixture.collections)
            default: return .init(status: 404)
            }
        }
    }

    func testDiscoversPrincipalHomeAndCollections() async throws {
        install()
        let probe = try await CalDAVAdapter.probe(server: server, login: "me@ya.test", password: "app-pass", http: StubURLProtocol.http())
        XCTAssertEqual(probe.principal.absoluteString, "https://caldav.test/principals/me/")
        XCTAssertEqual(probe.home.absoluteString, "https://caldav.test/calendars/me/")
        let adapter = CalDAVAdapter(server: server, login: "me@ya.test", password: "app-pass", http: StubURLProtocol.http())
        let collections = try await adapter.collections()
        XCTAssertEqual(
            collections.map(\.externalID), ["https://caldav.test/calendars/me/work/", "https://caldav.test/calendars/me/shared/"])
        XCTAssertEqual(collections.first?.name, "Работа B")
        XCTAssertEqual(collections.first?.color, "#FF2968")
        XCTAssertEqual(collections.first?.access, .write)
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.value(forHTTPHeaderField: "Depth") == "1" })
    }

    func testDetectsAutoSchedule() async throws {
        install(schedule: true)
        let on = try await CalDAVAdapter.probe(server: server, login: "me@ya.test", password: "app-pass", http: StubURLProtocol.http())
        XCTAssertTrue(on.schedules)
        install(schedule: false)
        let off = try await CalDAVAdapter.probe(server: server, login: "me@ya.test", password: "app-pass", http: StubURLProtocol.http())
        XCTAssertFalse(off.schedules)
        let adapter = CalDAVAdapter(server: server, login: "me@ya.test", password: "app-pass", http: StubURLProtocol.http())
        let schedules = await adapter.schedulesInvitations
        XCTAssertFalse(schedules)
    }

    func testReadOnlyCollectionHasReadAccess() async throws {
        install()
        let adapter = CalDAVAdapter(server: server, login: "me@ya.test", password: "app-pass", http: StubURLProtocol.http())
        let shared = try await adapter.collections().first { $0.name == "Общий" }
        XCTAssertEqual(shared?.access, .read)
    }

    func testRefusesPlainHTTP() async {
        do {
            _ = try await CalDAVAdapter.probe(
                server: URL(string: "http://caldav.test")!, login: "a", password: "b", http: StubURLProtocol.http())
            XCTFail("plain HTTP must be refused")
        } catch { XCTAssertEqual(error as? CalendarFailure, .invalidInput("https required")) }
    }

    func testProviderSuggestions() {
        XCTAssertEqual(CalDAVProviders.suggestion(email: "me@yandex.ru", imapHost: nil)?.absoluteString, "https://caldav.yandex.ru")
        XCTAssertEqual(
            CalDAVProviders.suggestion(email: "me@corp.test", imapHost: "imap.yandex.com")?.absoluteString, "https://caldav.yandex.ru")
        XCTAssertEqual(CalDAVProviders.suggestion(email: "me@icloud.com", imapHost: nil)?.absoluteString, "https://caldav.icloud.com")
        XCTAssertEqual(
            CalDAVProviders.suggestion(email: "me@corp.test", imapHost: "imap.mail.me.com")?.absoluteString, "https://caldav.icloud.com")
        XCTAssertEqual(CalDAVProviders.suggestion(email: "me@fastmail.com", imapHost: nil)?.absoluteString, "https://caldav.fastmail.com")
        XCTAssertNil(CalDAVProviders.suggestion(email: "me@gmail.com", imapHost: nil))
        XCTAssertNil(CalDAVProviders.suggestion(email: "me@corp.test", imapHost: "mail.corp.test"))
    }
}

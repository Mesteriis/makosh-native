import Foundation
import XCTest
@testable import MakoshCalendar

final class CalDAVSyncTests: XCTestCase {
    private let server = URL(string: "https://caldav.test")!
    private lazy var collection = CalendarCollection(
        accountID: UUID(), externalID: "https://caldav.test/calendars/me/work/", name: "Работа B")
    private let window = DateInterval(start: Date(timeIntervalSince1970: 1_794_096_000), duration: 90 * 86400)

    static func ics(_ uid: String, extra: String = "") -> String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:\(uid)\r\nDTSTART:20261110T090000Z\r\nDTEND:20261110T100000Z\r\nSUMMARY:Событие \(uid)\r\n\(extra)END:VEVENT\r\nEND:VCALENDAR\r\n"
    }
    static let invite = ics(
        "inv-1",
        extra:
            "ORGANIZER:mailto:boss@x.test\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:boss@x.test\r\nATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@ya.test\r\n"
    )

    private func response(_ href: String, etag: String? = nil, data: String? = nil, status: String = "200 OK") -> String {
        if status != "200 OK" { return "<d:response><d:href>\(href)</d:href><d:status>HTTP/1.1 \(status)</d:status></d:response>" }
        return "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>" + (etag.map { "<d:getetag>\($0)</d:getetag>" } ?? "")
            + (data.map { "<c:calendar-data>\($0.xmlEscaped)</c:calendar-data>" } ?? "")
            + "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    private func adapter(schedule: Bool = true, _ routes: @escaping (URLRequest, String) -> StubURLProtocol.Reply?) -> CalDAVAdapter {
        StubURLProtocol.install { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if let reply = routes(request, body) { return reply }
            switch (request.httpMethod, request.url?.path) {
            case ("PROPFIND", "/.well-known/caldav"): return .init(status: 207, body: CalDAVFixture.principal)
            case ("PROPFIND", "/principals/me"), ("PROPFIND", "/principals/me/"): return .init(status: 207, body: CalDAVFixture.home)
            case ("OPTIONS", _):
                return .init(status: 200, headers: ["DAV": schedule ? "1, calendar-access, calendar-auto-schedule" : "1, calendar-access"])
            default: return .init(status: 404)
            }
        }
        return CalDAVAdapter(server: server, login: "me@ya.test", password: "p", http: StubURLProtocol.http())
    }
    private func requests(_ method: String) -> [URLRequest] { StubURLProtocol.requests.filter { $0.httpMethod == method } }
    private func body(_ request: URLRequest) -> String { String(decoding: request.httpBody ?? Data(), as: UTF8.self) }

    func testSyncCollectionAppliesChangesAndRemovals() async throws {
        let adapter = adapter { request, body in
            guard request.httpMethod == "REPORT", body.contains("sync-collection") else { return nil }
            XCTAssertTrue(body.contains("<d:sync-token>t1</d:sync-token>"))
            return .init(
                status: 207,
                body: CalDAVFixture.multistatus(
                    self.response("/calendars/me/work/a.ics", etag: "\"2\"", data: Self.invite)
                        + self.response("/calendars/me/work/b.ics", status: "404 Not Found") + "<d:sync-token>t2</d:sync-token>"))
        }
        let changes = try await adapter.changes(collection: collection, cursor: CalDAVCursor.token("t1").data, window: window)
        XCTAssertFalse(changes.full)
        XCTAssertEqual(changes.events.map(\.externalID), ["https://caldav.test/calendars/me/work/a.ics"])
        XCTAssertEqual(changes.events.first?.etag, "\"2\"")
        XCTAssertEqual(changes.events.first?.selfResponse, .needsAction, "the attendee with the login is the user")
        XCTAssertEqual(changes.removedExternalIDs, ["https://caldav.test/calendars/me/work/b.ics"])
        XCTAssertEqual(CalDAVCursor(data: changes.cursor), .token("t2"))
    }

    func testETagDiffWithoutSyncSupport() async throws {
        let adapter = adapter { request, body in
            guard request.httpMethod == "REPORT" else { return nil }
            if body.contains("calendar-query") {
                return .init(
                    status: 207,
                    body: CalDAVFixture.multistatus(
                        self.response("/calendars/me/work/a.ics", etag: "\"2\"") + self.response("/calendars/me/work/c.ics", etag: "\"1\""))
                )
            }
            if body.contains("calendar-multiget") {
                XCTAssertTrue(body.contains("/calendars/me/work/a.ics") && body.contains("/calendars/me/work/c.ics"))
                return .init(
                    status: 207,
                    body: CalDAVFixture.multistatus(
                        self.response("/calendars/me/work/a.ics", etag: "\"2\"", data: Self.ics("a"))
                            + self.response("/calendars/me/work/c.ics", etag: "\"1\"", data: Self.ics("c"))))
            }
            return .init(status: 403)
        }
        let previous = CalDAVCursor.etags([
            "https://caldav.test/calendars/me/work/a.ics": "\"1\"", "https://caldav.test/calendars/me/work/b.ics": "\"1\"",
        ])
        let changes = try await adapter.changes(collection: collection, cursor: previous.data, window: window)
        XCTAssertEqual(Set(changes.events.map(\.uid)), ["a", "c"])
        XCTAssertEqual(changes.removedExternalIDs, ["https://caldav.test/calendars/me/work/b.ics"])
        XCTAssertFalse(requests("REPORT").contains { body($0).contains("sync-collection") })
        guard case .etags(let map)? = CalDAVCursor(data: changes.cursor) else { return XCTFail("etag cursor expected") }
        XCTAssertEqual(map.count, 2)
    }

    func testInvalidSyncTokenFallsBackToFull() async throws {
        let adapter = adapter { request, body in
            guard request.httpMethod == "REPORT", body.contains("sync-collection") else { return nil }
            if body.contains("<d:sync-token>bad</d:sync-token>") { return .init(status: 403) }
            return .init(
                status: 207,
                body: CalDAVFixture.multistatus(
                    self.response("/calendars/me/work/a.ics", etag: "\"1\"", data: Self.ics("a")) + "<d:sync-token>t9</d:sync-token>"))
        }
        let changes = try await adapter.changes(collection: collection, cursor: CalDAVCursor.token("bad").data, window: window)
        XCTAssertTrue(changes.full)
        XCTAssertEqual(changes.events.map(\.uid), ["a"])
        XCTAssertEqual(CalDAVCursor(data: changes.cursor), .token("t9"))
    }

    func testCreateUsesIfNoneMatchAndUpdateIfMatch() async throws {
        let adapter = adapter { request, _ in
            switch request.httpMethod {
            case "PUT": return .init(status: 201, headers: ["ETag": "\"5\""])
            case "GET": return .init(status: 200, headers: ["ETag": "\"5\""], body: Data(Self.ics("a").utf8))
            default: return nil
            }
        }
        let ref = try await adapter.create(
            CalendarEvent.fixture(start: 9, end: 10, collectionID: collection.id), in: collection, notify: false)
        XCTAssertTrue(ref.externalID.hasPrefix("https://caldav.test/calendars/me/work/") && ref.externalID.hasSuffix(".ics"))
        XCTAssertEqual(ref.etag, "\"5\"")
        let put = try XCTUnwrap(requests("PUT").last)
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "text/calendar; charset=utf-8")
        _ = try await adapter.update(
            CalendarEvent.fixture(start: 9, end: 10, collectionID: collection.id), ref: ref, in: collection, notify: false)
        XCTAssertEqual(requests("PUT").last?.value(forHTTPHeaderField: "If-Match"), "\"5\"")
        XCTAssertEqual(requests("PUT").last?.url?.absoluteString, ref.externalID)
    }

    func testAttendeesOmittedWithoutServerScheduling() async throws {
        let plain = adapter(schedule: false) { request, _ in
            request.httpMethod == "PUT" ? .init(status: 201, headers: ["ETag": "\"1\""]) : nil
        }
        var event = CalendarEvent.fixture(start: 9, end: 10, collectionID: collection.id)
        event.attendees = [.init(email: "bob@x.test")]
        _ = try await plain.create(event, in: collection, notify: true)
        let text = body(try XCTUnwrap(requests("PUT").last))
        XCTAssertFalse(text.contains("ATTENDEE"))
        XCTAssertFalse(text.contains("ORGANIZER"))
        let scheduling = adapter(schedule: true) { request, _ in
            request.httpMethod == "PUT" ? .init(status: 201, headers: ["ETag": "\"1\""]) : nil
        }
        _ = try await scheduling.create(event, in: collection, notify: true)
        let invited = body(try XCTUnwrap(requests("PUT").last))
        XCTAssertTrue(invited.contains("mailto:bob@x.test"))
        XCTAssertTrue(invited.contains("ORGANIZER:mailto:me@ya.test"))
    }

    func testRespondChangesOnlyOwnPartstat() async throws {
        let adapter = adapter { request, _ in
            switch request.httpMethod {
            case "GET": return .init(status: 200, headers: ["ETag": "\"3\""], body: Data(Self.invite.utf8))
            case "PUT": return .init(status: 204, headers: ["ETag": "\"4\""])
            default: return nil
            }
        }
        let ref = try await adapter.respond(
            .declined, ref: RemoteEventRef(externalID: "https://caldav.test/calendars/me/work/a.ics", etag: "\"3\""), in: collection)
        XCTAssertEqual(ref.etag, "\"4\"")
        let put = try XCTUnwrap(requests("PUT").last)
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-Match"), "\"3\"")
        let text = body(put).replacingOccurrences(of: "\r\n ", with: "")
        XCTAssertTrue(text.contains("PARTSTAT=DECLINED:mailto:me@ya.test"))
        XCTAssertTrue(text.contains("PARTSTAT=ACCEPTED:mailto:boss@x.test"))
    }

    func testBusyCopyICSHasOnlyBusyFields() async throws {
        let adapter = adapter { request, _ in request.httpMethod == "PUT" ? .init(status: 201, headers: ["ETag": "\"1\""]) : nil }
        let start = Date(timeIntervalSince1970: 1_794_200_000)
        let copy = DesiredBusyCopy(
            sourceEventID: UUID(), occurrenceKey: start, targetCollectionID: collection.id,
            time: .timed(start: start, end: start.addingTimeInterval(1800), timeZone: nil))
        let ref = try await adapter.createBusyCopy(copy, in: collection)
        let text = body(try XCTUnwrap(requests("PUT").last))
        XCTAssertTrue(text.contains("SUMMARY:Занято"))
        for forbidden in ["DESCRIPTION", "LOCATION", "ATTENDEE", "VALARM"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
        _ = try await adapter.moveBusyCopy(
            ref: ref, to: .timed(start: start.addingTimeInterval(600), end: start.addingTimeInterval(2400), timeZone: nil),
            marker: copy.marker, in: collection)
        let moved = body(try XCTUnwrap(requests("PUT").last))
        let uid = { (text: String) in text.split(separator: "\r\n").first { $0.hasPrefix("UID:") } }
        XCTAssertEqual(uid(text), uid(moved), "a moved copy keeps its UID")
        XCTAssertEqual(requests("PUT").last?.url?.absoluteString, ref.externalID)
    }
}

final class CalDAVReviewFixesTests: XCTestCase {
    private lazy var collection = CalendarCollection(
        accountID: UUID(), externalID: "https://caldav.test/calendars/me/work/", name: "Работа B")
    private let window = DateInterval(start: Date(timeIntervalSince1970: 1_794_096_000), duration: 90 * 86400)
    static let series =
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:s\r\nDTSTART:20261109T090000Z\r\nDTEND:20261109T100000Z\r\nRRULE:FREQ=WEEKLY\r\nSUMMARY:Планёрка\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID:20261116T090000Z\r\nDTSTART:20261116T110000Z\r\nDTEND:20261116T120000Z\r\nSUMMARY:Планёрка (перенос)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

    private func adapter(schedule: Bool, get: String) -> CalDAVAdapter {
        StubURLProtocol.install { request in
            switch (request.httpMethod, request.url?.path) {
            case ("PROPFIND", "/.well-known/caldav"): return .init(status: 207, body: CalDAVFixture.principal)
            case ("PROPFIND", _): return .init(status: 207, body: CalDAVFixture.home)
            case ("OPTIONS", _): return .init(status: 200, headers: ["DAV": schedule ? "1, calendar-auto-schedule" : "1"])
            case ("GET", _): return .init(status: 200, headers: ["ETag": "\"3\""], body: Data(get.utf8))
            case ("PUT", _): return .init(status: 204, headers: ["ETag": "\"4\""])
            case ("REPORT", _):
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                XCTAssertFalse(body.contains("time-range"), "ETag listing must cover the whole calendar")
                return .init(
                    status: 207,
                    body: CalDAVFixture.multistatus(
                        "<d:response><d:href>/calendars/me/work/old.ics</d:href><d:propstat><d:prop><d:getetag>\"1\"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                    ))
            default: return .init(status: 404)
            }
        }
        return CalDAVAdapter(server: URL(string: "https://caldav.test")!, login: "me@ya.test", password: "p", http: StubURLProtocol.http())
    }

    func testUpdateKeepsOverridesOfTheResource() async throws {
        let adapter = adapter(schedule: true, get: Self.series)
        var master = try ICalendar.parse(Self.series, collectionID: collection.id).first { $0.recurrenceID == nil }!
        master.title = "Еженедельная планёрка"
        _ = try await adapter.update(
            master, ref: RemoteEventRef(externalID: "https://caldav.test/calendars/me/work/s.ics", etag: "\"3\""), in: collection,
            notify: false)
        let put = String(decoding: StubURLProtocol.requests.last { $0.httpMethod == "PUT" }?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(put.contains("RECURRENCE-ID"), "the moved occurrence must survive an edit of its series")
        XCTAssertTrue(put.contains("Еженедельная планёрка"))
    }

    func testUpdateOfAnInvitationKeepsItsAttendeesWithoutServerScheduling() async throws {
        let invite = CalDAVSyncTests.invite
        let adapter = adapter(schedule: false, get: invite)
        var event = try ICalendar.parse(invite, collectionID: collection.id)[0]
        event.reminders = [30]
        _ = try await adapter.update(
            event, ref: RemoteEventRef(externalID: "https://caldav.test/calendars/me/work/i.ics", etag: "\"3\""), in: collection,
            notify: false)
        let put = String(decoding: StubURLProtocol.requests.last { $0.httpMethod == "PUT" }?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(put.contains("ORGANIZER:mailto:boss@x.test"))
        XCTAssertTrue(put.contains("mailto:me@ya.test"))
    }

    func testETagListingCoversTheWholeCalendar() async throws {
        let adapter = adapter(schedule: true, get: "")
        let previous = CalDAVCursor.etags(["https://caldav.test/calendars/me/work/old.ics": "\"1\""])
        let changes = try await adapter.changes(collection: collection, cursor: previous.data, window: window)
        XCTAssertTrue(changes.removedExternalIDs.isEmpty, "an old event still on the server is not removed")
    }
}

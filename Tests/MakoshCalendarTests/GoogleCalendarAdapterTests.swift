import Foundation
import XCTest
@testable import MakoshCalendar

final class GoogleCalendarAdapterTests: XCTestCase {
    private let grant = GoogleGrant(subject: "10001", email: "me@gmail.test", scopes: [], refreshToken: "rt")
    private let api = "https://www.googleapis.com/calendar/v3"
    private lazy var collection = CalendarCollection(accountID: UUID(), externalID: "work#1@group.calendar.google.com", name: "Работа A")
    private let window = DateInterval(start: Date(timeIntervalSince1970: 1_794_096_000), duration: 90 * 86400)

    private func adapter(_ routes: @escaping (URLRequest) -> StubURLProtocol.Reply) -> GoogleCalendarAdapter {
        StubURLProtocol.install { request in
            if request.url?.host == "oauth2.googleapis.com" { return .init(body: Data(#"{"access_token":"at","expires_in":3600}"#.utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at")
            return routes(request)
        }
        let http = StubURLProtocol.http()
        let oauth = GoogleOAuth(client: GoogleOAuthClient(clientID: "c", clientSecret: "s"), http: http, openBrowser: { _ in })
        return GoogleCalendarAdapter(grant: grant, oauth: oauth, http: http)
    }
    private func json(_ text: String, status: Int = 200) -> StubURLProtocol.Reply {
        .init(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }
    private var apiRequests: [URLRequest] { StubURLProtocol.requests.filter { $0.url?.host == "www.googleapis.com" } }
    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    static let eventsPage = """
        {"items":[
          {"id":"e1","etag":"\\"1\\"","iCalUID":"e1@google.com","status":"confirmed","summary":"Созвон A","description":"Ссылка https://telemost.yandex.ru/j/555",
           "start":{"dateTime":"2026-11-10T10:00:00+03:00","timeZone":"Europe/Moscow"},"end":{"dateTime":"2026-11-10T11:00:00+03:00","timeZone":"Europe/Moscow"},
           "organizer":{"email":"boss@x.test"},"attendees":[{"email":"boss@x.test","organizer":true,"responseStatus":"accepted"},{"email":"me@gmail.test","self":true,"responseStatus":"needsAction"}],
           "reminders":{"useDefault":false,"overrides":[{"method":"popup","minutes":15}]}},
          {"id":"e2","iCalUID":"e2@google.com","status":"confirmed","summary":"Отпуск","transparency":"transparent","start":{"date":"2026-12-29"},"end":{"date":"2027-01-03"},"reminders":{"useDefault":true}},
          {"id":"s1","iCalUID":"s1@google.com","status":"confirmed","summary":"Планёрка","start":{"dateTime":"2026-11-09T09:00:00Z"},"end":{"dateTime":"2026-11-09T09:30:00Z"},
           "recurrence":["RRULE:FREQ=WEEKLY;BYDAY=MO","EXDATE:20261116T090000Z"],"hangoutLink":"https://meet.google.com/abc"},
          {"id":"s1_20261123T090000Z","iCalUID":"s1@google.com","status":"cancelled","recurringEventId":"s1","originalStartTime":{"dateTime":"2026-11-23T09:00:00Z"}},
          {"id":"gone","status":"cancelled"},
          {"id":"c1","iCalUID":"c1@google.com","status":"confirmed","summary":"Занято","start":{"dateTime":"2026-11-11T14:00:00Z"},"end":{"dateTime":"2026-11-11T15:00:00Z"},
           "extendedProperties":{"private":{"makoshBusy":"6A7E4C2B-0000-4000-8000-000000000001;2026-11-11T14:00:00Z"}}}
        ],"nextPageToken":"p2"}
        """

    func testListsCollectionsWithAccess() async throws {
        let adapter = adapter { _ in
            self.json(
                ##"{"items":[{"id":"a@x","summary":"Работа","backgroundColor":"#16a765","accessRole":"owner"},{"id":"ru#holiday","summary":"Праздники","accessRole":"reader"}]}"##
            )
        }
        let collections = try await adapter.collections()
        XCTAssertEqual(collections.map(\.externalID), ["a@x", "ru#holiday"])
        XCTAssertEqual(collections.map(\.access), [.write, .read])
        XCTAssertEqual(collections.first?.color, "#16a765")
    }

    func testMapsTimedAllDayRecurringOverrideAttendeesAndMeeting() async throws {
        let adapter = adapter { request in
            request.url!.absoluteString.contains("pageToken=p2")
                ? self.json(#"{"items":[],"nextSyncToken":"sync-1"}"#) : self.json(Self.eventsPage)
        }
        let changes = try await adapter.changes(collection: collection, cursor: nil, window: window)
        XCTAssertTrue(changes.full)
        XCTAssertEqual(changes.cursor, Data("sync-1".utf8))
        XCTAssertEqual(changes.removedExternalIDs, ["gone"])
        let byID = Dictionary(uniqueKeysWithValues: changes.events.map { ($0.externalID!, $0) })
        let call = try XCTUnwrap(byID["e1"])
        XCTAssertEqual(call.uid, "e1@google.com")
        XCTAssertEqual(
            call.time,
            .timed(
                start: ISO8601DateFormatter().date(from: "2026-11-10T07:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-11-10T08:00:00Z")!, timeZone: "Europe/Moscow"))
        XCTAssertEqual(call.selfResponse, .needsAction)
        XCTAssertEqual(call.organizerEmail, "boss@x.test")
        XCTAssertEqual(call.reminders, [15])
        XCTAssertEqual(call.etag, "\"1\"")
        XCTAssertEqual(call.meetingURL?.host, "telemost.yandex.ru")
        let vacation = try XCTUnwrap(byID["e2"])
        XCTAssertEqual(
            vacation.time,
            .allDay(start: CalendarDay(year: 2026, month: 12, day: 29), endExclusive: CalendarDay(year: 2027, month: 1, day: 3)))
        XCTAssertEqual(vacation.transparency, .free)
        let series = try XCTUnwrap(byID["s1"])
        XCTAssertEqual(series.recurrence?.rrule, "FREQ=WEEKLY;BYDAY=MO")
        XCTAssertEqual(series.recurrence?.exdates.count, 1)
        XCTAssertEqual(series.meetingURL?.host, "meet.google.com")
        let cancelled = try XCTUnwrap(byID["s1_20261123T090000Z"])
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.uid, "s1@google.com")
        XCTAssertEqual(cancelled.recurrenceID, ISO8601DateFormatter().date(from: "2026-11-23T09:00:00Z"))
        let copy = try XCTUnwrap(byID["c1"])
        XCTAssertEqual(copy.busyMarker?.sourceEventID, UUID(uuidString: "6A7E4C2B-0000-4000-8000-000000000001"))
        XCTAssertEqual(changes.busyCopies.map(\.externalID), ["c1"])
        XCTAssertEqual(changes.busyCopies.first?.collectionID, collection.id)
        let first = try XCTUnwrap(apiRequests.first?.url?.absoluteString)
        XCTAssertTrue(first.contains("/calendars/work%231@group.calendar.google.com/events"))
        XCTAssertTrue(first.contains("showDeleted=true"))
        XCTAssertTrue(first.contains("timeMin="))
    }

    func testPagesAndStoresSyncToken() async throws {
        let adapter = adapter { _ in self.json(#"{"items":[],"nextSyncToken":"sync-2"}"#) }
        let changes = try await adapter.changes(collection: collection, cursor: Data("sync-1".utf8), window: window)
        XCTAssertFalse(changes.full)
        XCTAssertEqual(changes.cursor, Data("sync-2".utf8))
        XCTAssertTrue(apiRequests.first!.url!.absoluteString.contains("syncToken=sync-1"))
        XCTAssertFalse(apiRequests.first!.url!.absoluteString.contains("timeMin"))
    }

    func testGoneTriggersFullResync() async throws {
        let adapter = adapter { request in
            request.url!.absoluteString.contains("syncToken=old")
                ? self.json("{}", status: 410) : self.json(#"{"items":[],"nextSyncToken":"fresh"}"#)
        }
        let changes = try await adapter.changes(collection: collection, cursor: Data("old".utf8), window: window)
        XCTAssertTrue(changes.full)
        XCTAssertEqual(changes.cursor, Data("fresh".utf8))
        XCTAssertEqual(apiRequests.count, 2)
    }

    func testBusyCopyBodyHasOnlyBusyFields() async throws {
        let adapter = adapter { _ in self.json(#"{"id":"new","etag":"\"9\""}"#) }
        let start = Date(timeIntervalSince1970: 1_794_200_000)
        let copy = DesiredBusyCopy(
            sourceEventID: UUID(), occurrenceKey: start, targetCollectionID: collection.id,
            time: .timed(start: start, end: start.addingTimeInterval(3600), timeZone: nil))
        let ref = try await adapter.createBusyCopy(copy, in: collection)
        XCTAssertEqual(ref, RemoteEventRef(externalID: "new", etag: "\"9\""))
        let request = try XCTUnwrap(apiRequests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url!.absoluteString.contains("sendUpdates=none"))
        let json = body(request)
        XCTAssertEqual(Set(json.keys), ["summary", "start", "end", "transparency", "visibility", "reminders", "extendedProperties"])
        XCTAssertEqual(json["summary"] as? String, "Занято")
        XCTAssertEqual(json["visibility"] as? String, "private")
        XCTAssertEqual(json["transparency"] as? String, "opaque")
        let marker = ((json["extendedProperties"] as? [String: Any])?["private"] as? [String: Any])?["makoshBusy"] as? String
        XCTAssertEqual(marker?.hasPrefix(copy.sourceEventID.uuidString), true)
    }

    func testInviteSendsUpdatesAllAndCopyNone() async throws {
        let adapter = adapter { _ in self.json(#"{"id":"n1","etag":"\"1\""}"#) }
        var event = CalendarEvent.fixture(start: 10, end: 11, collectionID: collection.id)
        event.attendees = [.init(email: "bob@x.test")]
        _ = try await adapter.create(event, in: collection, notify: true)
        XCTAssertTrue(apiRequests.last!.url!.absoluteString.contains("sendUpdates=all"))
        let json = body(apiRequests.last!)
        XCTAssertEqual((json["attendees"] as? [[String: Any]])?.compactMap { $0["email"] as? String }, ["bob@x.test"])
        _ = try await adapter.create(CalendarEvent.fixture(start: 12, end: 13, collectionID: collection.id), in: collection, notify: false)
        XCTAssertTrue(apiRequests.last!.url!.absoluteString.contains("sendUpdates=none"))
    }

    func testRespondPatchesOnlySelfAttendee() async throws {
        let current =
            #"{"id":"e1","etag":"\"1\"","attendees":[{"email":"boss@x.test","organizer":true,"responseStatus":"accepted"},{"email":"me@gmail.test","self":true,"responseStatus":"needsAction"}]}"#
        let adapter = adapter { request in request.httpMethod == "GET" ? self.json(current) : self.json(#"{"id":"e1","etag":"\"2\""}"#) }
        let ref = try await adapter.respond(.declined, ref: RemoteEventRef(externalID: "e1", etag: "\"1\""), in: collection)
        XCTAssertEqual(ref.etag, "\"2\"")
        let patch = try XCTUnwrap(apiRequests.last)
        XCTAssertEqual(patch.httpMethod, "PATCH")
        let attendees = try XCTUnwrap(body(patch)["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.map { $0["responseStatus"] as? String }, ["accepted", "declined"])
        XCTAssertEqual(Set(body(patch).keys), ["attendees"])
    }

    func testFindByICalUID() async throws {
        let adapter = adapter { _ in self.json(Self.eventsPage) }
        let found = try await adapter.find(uid: "e1@google.com", in: collection)
        XCTAssertEqual(found?.externalID, "e1")
        XCTAssertTrue(apiRequests.last!.url!.absoluteString.contains("iCalUID=e1@google.com"))
    }

    func testPreconditionFailedIsNotRejected() async {
        let adapter = adapter { _ in self.json("{}", status: 412) }
        do {
            _ = try await adapter.update(
                CalendarEvent.fixture(start: 1, end: 2), ref: RemoteEventRef(externalID: "e1", etag: "\"1\""), in: collection, notify: false
            )
            XCTFail("412 must throw")
        } catch { XCTAssertEqual(error as? CalendarHTTPError, .preconditionFailed) }
        XCTAssertEqual(apiRequests.last?.value(forHTTPHeaderField: "If-Match"), "\"1\"")
    }
}

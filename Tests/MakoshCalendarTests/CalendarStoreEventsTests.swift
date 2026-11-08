import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarStoreEventsTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_794_096_000)

    private func event(in collection: UUID, _ start: Double, _ end: Double, external: String? = nil) -> CalendarEvent {
        CalendarEvent(
            collectionID: collection, externalID: external, uid: UUID().uuidString, title: "Событие",
            time: .timed(start: day.addingTimeInterval(start * 3600), end: day.addingTimeInterval(end * 3600), timeZone: "Europe/Moscow"))
    }

    func testInsertUpdateKeepsAppendOnlyVersions() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let (_, local) = try await store.localAccount()
        let inserted = try await store.insert(event(in: local.id, 10, 11), actor: .user)
        XCTAssertEqual(inserted.revision, 1)
        var edit = inserted
        edit.title = "Новое"
        let updated = try await store.update(edit, expectedRevision: 1, actor: .user)
        XCTAssertEqual(updated.revision, 2)
        let versions = try await store.versions(eventID: inserted.id)
        XCTAssertEqual(versions.map(\.revision), [1, 2])
        XCTAssertEqual(versions.map(\.event.title), ["Событие", "Новое"])
        XCTAssertEqual(versions.map(\.actor), [.user, .user])
    }

    func testStaleRevisionRefused() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let (_, local) = try await store.localAccount()
        let inserted = try await store.insert(event(in: local.id, 10, 11), actor: .user)
        _ = try await store.update(inserted, expectedRevision: 1, actor: .user)
        do {
            _ = try await store.update(inserted, expectedRevision: 1, actor: .user)
            XCTFail("stale revision must be refused")
        } catch let failure as CalendarFailure { XCTAssertEqual(failure, .staleRevision) }
    }

    func testObserveUpsertsByExternalIDAndKeepsTaskLink() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let collection = UUID()
        let task = UUID()
        var first = event(in: collection, 9, 10, external: "g-1")
        first.taskID = task
        let stored = try await store.observe(first, collectionID: collection)
        var second = event(in: collection, 11, 12, external: "g-1")
        second.title = "Перенесли"
        let observed = try await store.observe(second, collectionID: collection)
        XCTAssertEqual(observed.id, stored.id)
        XCTAssertEqual(observed.title, "Перенесли")
        XCTAssertEqual(observed.taskID, task)
        XCTAssertEqual(observed.revision, 2)
        let versions = try await store.versions(eventID: stored.id)
        XCTAssertEqual(versions.map(\.actor), [.remote, .remote])
    }

    func testObserveRemovalMarksButKeepsHistory() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let collection = UUID()
        let stored = try await store.observe(event(in: collection, 9, 10, external: "g-2"), collectionID: collection)
        try await store.observeRemoval(externalID: "g-2", collectionID: collection)
        let read = try await store.event(id: stored.id)
        XCTAssertNotNil(read?.deletedAt)
        let versions = try await store.versions(eventID: stored.id)
        XCTAssertEqual(versions.count, 2)
        let window = try await store.events(
            collectionIDs: [collection], from: day, to: day.addingTimeInterval(86400), includeCopies: true)
        XCTAssertTrue(window.isEmpty)
    }

    func testPrivateFieldsAreNotStoredInClear() async throws {
        let db = try calendarDatabase()
        let store = try await calendarStore(db)
        let (_, local) = try await store.localAccount()
        var secret = event(in: local.id, 10, 11)
        secret.notes = "секрет-описание"
        secret.location = "Клиника на Пушкина"
        secret.attendees = [.init(email: "doctor@clinic.test")]
        secret.organizerEmail = "doctor@clinic.test"
        secret.meetingURL = URL(string: "https://telemost.yandex.ru/j/42")
        let stored = try await store.insert(secret, actor: .user)
        let raw = try db.execute(
            "SELECT e.data::text || e.sealed || v.data::text || v.sealed FROM \"\(db.schema)\".calendar_events e JOIN \"\(db.schema)\".calendar_event_versions v ON v.event_id = e.id"
        )
        for clear in ["секрет-описание", "Клиника", "doctor@clinic.test", "telemost"] {
            XCTAssertFalse(raw[0][0].contains(clear), clear)
        }
        let read = try await store.event(id: stored.id)
        XCTAssertEqual(read?.notes, "секрет-описание")
        XCTAssertEqual(read?.location, "Клиника на Пушкина")
        XCTAssertEqual(read?.attendees.map(\.email), ["doctor@clinic.test"])
        XCTAssertEqual(read?.meetingURL, secret.meetingURL)
    }

    func testEventsWindowReturnsMastersAndOverlaps() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let (_, local) = try await store.localAccount()
        let inside = try await store.insert(event(in: local.id, 10, 11), actor: .user)
        _ = try await store.insert(event(in: local.id, 48, 49), actor: .user)
        var series = event(in: local.id, -240, -239)
        series.recurrence = CalendarRecurrence(rrule: "FREQ=DAILY")
        let master = try await store.insert(series, actor: .user)
        var copy = event(in: local.id, 12, 13)
        copy.busyMarker = .init(sourceEventID: UUID(), occurrenceStart: day)
        let copyStored = try await store.insert(copy, actor: .engine)
        let withoutCopies = try await store.events(
            collectionIDs: [local.id], from: day, to: day.addingTimeInterval(86400), includeCopies: false)
        XCTAssertEqual(Set(withoutCopies.map(\.id)), [inside.id, master.id])
        let withCopies = try await store.events(
            collectionIDs: [local.id], from: day, to: day.addingTimeInterval(86400), includeCopies: true)
        XCTAssertEqual(Set(withCopies.map(\.id)), [inside.id, master.id, copyStored.id])
    }

    func testCursorRoundTrip() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let collection = UUID()
        let empty = try await store.cursor(collectionID: collection)
        XCTAssertNil(empty)
        try await store.saveCursor(Data("token-1".utf8), collectionID: collection)
        let saved = try await store.cursor(collectionID: collection)
        XCTAssertEqual(saved, Data("token-1".utf8))
        try await store.saveCursor(nil, collectionID: collection)
        let cleared = try await store.cursor(collectionID: collection)
        XCTAssertNil(cleared)
    }

    func testOversizedEventRejected() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let (_, local) = try await store.localAccount()
        var huge = event(in: local.id, 10, 11)
        huge.notes = String(repeating: "x", count: 1_100_000)
        do {
            _ = try await store.insert(huge, actor: .user)
            XCTFail("oversized event must be refused")
        } catch let failure as CalendarFailure { XCTAssertEqual(failure, .invalidInput("event too large")) }
    }
}

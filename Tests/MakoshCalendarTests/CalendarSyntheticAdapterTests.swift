import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarSyntheticAdapterTests: XCTestCase {
    private let remote = RemoteCollection(externalID: "work-a", name: "Работа A", color: nil, access: .write)
    private lazy var collection = CalendarCollection(accountID: UUID(), externalID: "work-a", name: "Работа A")
    private let window = DateInterval(start: Date(timeIntervalSince1970: 1_794_096_000), duration: 90 * 86400)

    func testSyntheticAppliesThenFailsOnUnknown() async throws {
        let adapter = CalendarSyntheticAdapter(collections: [remote], events: [:])
        await adapter.failNext(.unknownOutcome(stage: "create"))
        do {
            _ = try await adapter.create(
                CalendarEvent.fixture(start: 9, end: 10, collectionID: collection.id), in: collection, notify: false)
            XCTFail("failNext must throw")
        } catch { XCTAssertEqual(error as? CalendarFailure, .unknownOutcome(stage: "create")) }
        let stored = await adapter.externalEvents(collectionExternalID: "work-a")
        XCTAssertEqual(stored.count, 1, "an unknown outcome still applied the write")
        await adapter.failNext(.rejected(code: 403, stage: "create"))
        _ = try? await adapter.create(CalendarEvent.fixture(start: 11, end: 12, collectionID: collection.id), in: collection, notify: false)
        let after = await adapter.externalEvents(collectionExternalID: "work-a")
        XCTAssertEqual(after.count, 1, "a rejection applies nothing")
    }

    func testSyntheticTamperShiftsCopyAndChangesReportIt() async throws {
        let adapter = CalendarSyntheticAdapter(collections: [remote], events: [:])
        let start = Date(timeIntervalSince1970: 1_794_200_000)
        let copy = DesiredBusyCopy(
            sourceEventID: UUID(), occurrenceKey: start, targetCollectionID: collection.id,
            time: .timed(start: start, end: start.addingTimeInterval(3600), timeZone: nil))
        let ref = try await adapter.createBusyCopy(copy, in: collection)
        let first = try await adapter.changes(collection: collection, cursor: nil, window: window)
        XCTAssertEqual(first.busyCopies.map(\.externalID), [ref.externalID])
        await adapter.tamper(externalID: ref.externalID, collectionExternalID: "work-a", shiftMinutes: 30)
        let second = try await adapter.changes(collection: collection, cursor: first.cursor, window: window)
        XCTAssertEqual(
            second.busyCopies.first?.time, .timed(start: start.addingTimeInterval(1800), end: start.addingTimeInterval(5400), timeZone: nil)
        )
        XCTAssertFalse(second.full)
    }

    func testInvitationsCountedOnlyWhenNotified() async throws {
        let adapter = CalendarSyntheticAdapter(collections: [remote], events: [:])
        var event = CalendarEvent.fixture(start: 9, end: 10, collectionID: collection.id)
        event.attendees = [.init(email: "bob@x.test")]
        _ = try await adapter.create(event, in: collection, notify: true)
        _ = try await adapter.create(CalendarEvent.fixture(start: 11, end: 12, collectionID: collection.id), in: collection, notify: false)
        let sent = await adapter.sentInvitations
        XCTAssertEqual(sent, [event.uid])
        let found = try await adapter.find(uid: event.uid, in: collection)
        XCTAssertEqual(found?.title, event.title)
    }
}

import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarSyntheticSeedTests: XCTestCase {
    private func seeded() async throws -> (CalendarServiceHarness, [String: CalendarSyntheticAdapter]) {
        let adapters = CalendarSyntheticSeed.adapters(now: CalendarServiceHarness.start)
        let h = try await calendarHarness(adapters)
        try await CalendarSyntheticSeed.seed(service: h.service, adapters: adapters, now: CalendarServiceHarness.start)
        await h.service.settled()
        return (h, adapters)
    }

    func testSeedIsIdempotent() async throws {
        let (h, adapters) = try await seeded()
        let accounts = try await h.store.accounts().count
        let events = try await h.store.collections().count
        try await CalendarSyntheticSeed.seed(service: h.service, adapters: adapters, now: CalendarServiceHarness.start)
        let again = try await h.store.accounts().count
        XCTAssertEqual(again, accounts)
        let collections = try await h.store.collections().count
        XCTAssertEqual(collections, events)
        XCTAssertEqual(accounts, 5, "local, two Google, Yandex CalDAV, holidays")
    }

    func testSeedProducesBusyCopiesInBothWorkCalendars() async throws {
        let (_, adapters) = try await seeded()
        for name in [CalendarSyntheticSeed.workA, CalendarSyntheticSeed.workB] {
            let collection = try XCTUnwrap(adapters[name])
            let external = try await collection.collections()
            let copies = await collection.externalEvents(collectionExternalID: external[0].externalID).filter { $0.busyMarker != nil }
            XCTAssertFalse(copies.isEmpty, name)
            XCTAssertTrue(copies.allSatisfy { $0.title == "Занято" && $0.notes.isEmpty })
        }
    }

    func testSeedLeavesAnUnknownAttemptAndAnExternalConflict() async throws {
        let (h, _) = try await seeded()
        let snapshot = try await h.service.snapshot(window: DateInterval(start: h.at(0), duration: 7 * 86400))
        XCTAssertTrue(snapshot.openAttempts.contains { $0.state == .unknown })
        XCTAssertFalse(snapshot.externalConflicts.isEmpty)
        XCTAssertTrue(snapshot.events.values.contains { $0.meetingURL?.host == "telemost.yandex.ru" })
    }
}

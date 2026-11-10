import Foundation
import XCTest
@testable import MakoshCalendar

/// A synthetic calendar whose every successful write runs a hook afterwards: the test
/// breaks the local store between the server's answer and the attempt's settlement.
actor HookedCalendarAdapter: CalendarAdapter {
    private let inner: CalendarSyntheticAdapter
    private var afterWrite: (@Sendable () throws -> Void)?

    init(_ inner: CalendarSyntheticAdapter) { self.inner = inner }
    func setAfterWrite(_ hook: (@Sendable () throws -> Void)?) { afterWrite = hook }

    func collections() async throws -> [RemoteCollection] { try await inner.collections() }
    func changes(collection: CalendarCollection, cursor: Data?, window: DateInterval) async throws -> RemoteChangeSet {
        try await inner.changes(collection: collection, cursor: cursor, window: window)
    }
    func create(_ event: CalendarEvent, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef {
        let ref = try await inner.create(event, in: collection, notify: notify)
        try afterWrite?()
        return ref
    }
    func update(_ event: CalendarEvent, ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef
    {
        try await inner.update(event, ref: ref, in: collection, notify: notify)
    }
    func delete(ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws {
        try await inner.delete(ref: ref, in: collection, notify: notify)
    }
    func respond(_ response: CalendarResponse, ref: RemoteEventRef, in collection: CalendarCollection) async throws -> RemoteEventRef {
        try await inner.respond(response, ref: ref, in: collection)
    }
    func find(uid: String, in collection: CalendarCollection) async throws -> CalendarEvent? {
        try await inner.find(uid: uid, in: collection)
    }
    func createBusyCopy(_ copy: DesiredBusyCopy, in collection: CalendarCollection) async throws -> RemoteEventRef {
        try await inner.createBusyCopy(copy, in: collection)
    }
    func moveBusyCopy(
        ref: RemoteEventRef, to time: CalendarEventTime, marker: CalendarBusyMarker, in collection: CalendarCollection
    ) async throws -> RemoteEventRef {
        try await inner.moveBusyCopy(ref: ref, to: time, marker: marker, in: collection)
    }
    var schedulesInvitations: Bool { get async { await inner.schedulesInvitations } }
}

/// `unknown` is settled by reading or dismissal, never by resending; a local failure after
/// the server answered is not a refusal.
final class CalendarAttemptSettlementTests: XCTestCase {
    private func original(_ w: BusyWorld) -> CalendarEventTime { .timed(start: w.h.at(14), end: w.h.at(15), timeZone: nil) }

    private func placedCopy(_ w: BusyWorld) async throws -> (CalendarEvent, CalendarEvent) {
        guard case .saved(let event) = try await w.h.service.create(w.draft(in: w.personal, 14, 15), ignoringConflicts: false) else {
            throw CalendarFailure.invalidInput("saved expected")
        }
        let copies = await w.copies(w.a, "work-a")
        let copy = try XCTUnwrap(copies.first)
        return (event, copy)
    }

    /// A copy shifted on the server is moved back by the pass; the answer to that move is lost.
    private func tamperedCopy(_ w: BusyWorld, applying: Bool) async throws -> CalendarAttempt {
        let (_, copy) = try await placedCopy(w)
        let externalID = try XCTUnwrap(copy.externalID)
        await w.a.tamper(externalID: externalID, collectionExternalID: "work-a", shiftMinutes: 30)
        if applying {
            await w.a.failNext(.unknownOutcome(stage: "copy"))
        } else {
            await w.a.failNextWithoutApplying(.unknownOutcome(stage: "copy"))
        }
        await w.h.service.sync(accountID: w.workA.accountID)
        await w.h.service.settled()
        let open = try await w.h.store.openAttempts()
        XCTAssertEqual(open.map(\.kind), [.moveCopy])
        XCTAssertEqual(open.map(\.state), [.unknown])
        return try XCTUnwrap(open.first)
    }

    func testUnknownCopyMoveThatLandedIsConfirmedByReadingWithoutSecondPut() async throws {
        let w = try await busyWorld()
        let attempt = try await tamperedCopy(w, applying: true)
        let onServer = await w.copies(w.a, "work-a")
        XCTAssertEqual(onServer.map(\.time), [original(w)], "the move reached the server before the answer was lost")
        let etagBefore = onServer.first?.etag

        await w.h.service.sync(accountID: w.workA.accountID)
        await w.h.service.settled()
        let settled = try await w.h.store.attempt(id: attempt.id)
        XCTAssertEqual(settled?.state, .confirmed)
        let stillOpen = try await w.h.store.openAttempts()
        XCTAssertTrue(stillOpen.isEmpty)
        let after = await w.copies(w.a, "work-a")
        XCTAssertEqual(after.map(\.etag), [etagBefore], "no second PUT")
        let records = try await w.h.store.busyCopies(targetCollectionID: w.workA.id)
        XCTAssertEqual(records.map(\.time), [original(w)])
        XCTAssertEqual(records.map(\.state), [.placed])
    }

    func testUnknownCopyMoveThatNeverLandedIsRejectedByReadingThenMovedAnew() async throws {
        let w = try await busyWorld()
        let attempt = try await tamperedCopy(w, applying: false)

        await w.h.service.sync(accountID: w.workA.accountID)
        await w.h.service.settled()
        let settled = try await w.h.store.attempt(id: attempt.id)
        XCTAssertEqual(settled?.state, .rejected, "the server still shows the shifted time")
        let stillOpen = try await w.h.store.openAttempts()
        XCTAssertTrue(stillOpen.isEmpty)
        let after = await w.copies(w.a, "work-a")
        XCTAssertEqual(after.map(\.time), [original(w)], "a new attempt moves the copy back")
        let count = try w.h.db.execute("SELECT count(*) FROM \"\(w.h.db.schema)\".calendar_attempts WHERE kind = 'moveCopy'")
        XCTAssertEqual(count, [["2"]])
    }

    func testUnknownCopyDeleteThatLandedIsConfirmedByReading() async throws {
        let w = try await busyWorld()
        let (event, _) = try await placedCopy(w)
        await w.a.failNext(.unknownOutcome(stage: "copy"))
        try await w.h.service.delete(eventID: event.id, occurrenceKey: nil, scope: .series)
        await w.h.service.settled()
        let open = try await w.h.store.openAttempts()
        XCTAssertEqual(open.map(\.kind), [.deleteCopy])
        XCTAssertEqual(open.map(\.state), [.unknown])
        let gone = await w.copies(w.a, "work-a")
        XCTAssertTrue(gone.isEmpty, "the delete reached the server before the answer was lost")

        await w.h.service.sync(accountID: w.workA.accountID)
        await w.h.service.settled()
        let settled = try await w.h.store.attempt(id: try XCTUnwrap(open.first?.id))
        XCTAssertEqual(settled?.state, .confirmed)
        let stillOpen = try await w.h.store.openAttempts()
        XCTAssertTrue(stillOpen.isEmpty)
        let records = try await w.h.store.busyCopies(targetCollectionID: w.workA.id)
        XCTAssertTrue(records.isEmpty)
    }

    func testUnknownCopyDeleteThatNeverLandedIsRejectedByReading() async throws {
        let w = try await busyWorld()
        let (event, _) = try await placedCopy(w)
        await w.a.failNextWithoutApplying(.unknownOutcome(stage: "copy"))
        try await w.h.service.delete(eventID: event.id, occurrenceKey: nil, scope: .series)
        await w.h.service.settled()
        let open = try await w.h.store.openAttempts()
        XCTAssertEqual(open.map(\.state), [.unknown])

        await w.h.service.sync(accountID: w.workA.accountID)
        await w.h.service.settled()
        let settled = try await w.h.store.attempt(id: try XCTUnwrap(open.first?.id))
        XCTAssertEqual(settled?.state, .rejected, "the copy is still on the server")
        let after = await w.copies(w.a, "work-a")
        XCTAssertTrue(after.isEmpty, "a new attempt removes it")
        let records = try await w.h.store.busyCopies(targetCollectionID: w.workA.id)
        XCTAssertTrue(records.isEmpty)
    }

    func testStorageFailureAfterServerCreateLeavesAttemptUnknownAndNoDuplicate() async throws {
        let inner = synthetic("work-a")
        let hooked = HookedCalendarAdapter(inner)
        let h = try await calendarHarness(adapters: ["Работа A": hooked])
        let account = try await h.service.addCalDAVAccount(
            name: "Работа A", server: URL(string: "https://a.test")!, login: "me@a.test", password: "p")
        let collections = try await h.store.collections()
        let collection = try XCTUnwrap(collections.first { $0.accountID == account.id })
        let db = h.db
        let attempts = "\"\(db.schema)\".calendar_attempts"
        await hooked.setAfterWrite {
            try db.execute("ALTER TABLE \(attempts) ADD CONSTRAINT no_confirm CHECK (state <> 'confirmed') NOT VALID")
        }
        let draft = CalendarDraft(
            collectionID: collection.id, title: "Созвон", notes: "", location: "",
            time: .timed(start: h.at(9), end: h.at(10), timeZone: nil), attendees: [])
        do {
            _ = try await h.service.create(draft, ignoringConflicts: true)
            XCTFail("the local failure reaches the user")
        } catch {
            guard case .storage = error as? CalendarFailure else { return XCTFail("storage expected, got \(error)") }
        }
        let open = try await h.store.openAttempts()
        XCTAssertEqual(open.map(\.kind), [.createEvent])
        XCTAssertEqual(open.map(\.state), [.unknown], "the server answered: not a refusal")
        let eventID = try XCTUnwrap(open.first?.eventID)
        let local = try await h.store.event(id: eventID)
        XCTAssertNil(local?.deletedAt, "no undo after a successful write")

        try db.execute("ALTER TABLE \(attempts) DROP CONSTRAINT no_confirm")
        await h.service.sync(accountID: account.id)
        await h.service.settled()
        let settled = try await h.store.attempt(id: try XCTUnwrap(open.first?.id))
        XCTAssertEqual(settled?.state, .confirmed)
        let live = try await h.store.liveEvents(collectionID: collection.id)
        XCTAssertEqual(live.map(\.id), [eventID], "the server's event is the local one, not a second row")
        XCTAssertNotNil(live.first?.externalID)
        let remote = await inner.externalEvents(collectionExternalID: "work-a")
        XCTAssertEqual(remote.count, 1)
    }
}

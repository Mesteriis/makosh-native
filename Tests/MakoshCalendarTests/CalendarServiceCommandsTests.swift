import Foundation
import XCTest
@testable import MakoshCalendar

/// Personal (local) + work A + work B (synthetic CalDAV), all in one busy group.
struct BusyWorld {
    let h: CalendarServiceHarness
    let personal: CalendarCollection
    let workA: CalendarCollection
    let workB: CalendarCollection
    let a: CalendarSyntheticAdapter
    let b: CalendarSyntheticAdapter
    let group: CalendarGroup

    func copies(_ adapter: CalendarSyntheticAdapter, _ externalID: String) async -> [CalendarEvent] {
        await adapter.externalEvents(collectionExternalID: externalID).filter { $0.busyMarker != nil }
    }
    func draft(
        in collection: CalendarCollection, _ from: Double, _ to: Double, title: String = "Стоматолог", attendees: [String] = []
    ) -> CalendarDraft {
        CalendarDraft(
            collectionID: collection.id, title: title, notes: "Клиника", location: "ул. Пушкина",
            time: .timed(start: h.at(from), end: h.at(to), timeZone: nil), attendees: attendees)
    }
}

extension XCTestCase {
    nonisolated(nonsending) func busyWorld(aEvents: [CalendarEvent] = [], bEvents: [CalendarEvent] = []) async throws -> BusyWorld {
        let a = synthetic("work-a", events: aEvents), b = synthetic("work-b", events: bEvents)
        let h = try await calendarHarness(["Работа A": a, "Работа B": b])
        let accountA = try await h.service.addCalDAVAccount(
            name: "Работа A", server: URL(string: "https://a.test")!, login: "me@a.test", password: "p")
        let accountB = try await h.service.addCalDAVAccount(
            name: "Работа B", server: URL(string: "https://b.test")!, login: "me@b.test", password: "p")
        let group = CalendarGroup(name: "Все")
        var collections = try await h.store.collections()
        for index in collections.indices { collections[index].groupIDs = [group.id] }
        try await h.service.applyGroupChange(collections: collections, groups: [group])
        let all = try await h.store.collections()
        return BusyWorld(
            h: h, personal: all.first { $0.externalID == "local" }!, workA: all.first { $0.accountID == accountA.id }!,
            workB: all.first { $0.accountID == accountB.id }!, a: a, b: b, group: group)
    }
}

final class CalendarServiceCommandsTests: XCTestCase {
    func testDentistInPersonalPlacesBusyInBothWorkCalendars() async throws {
        let w = try await busyWorld()
        let outcome = try await w.h.service.create(w.draft(in: w.personal, 14, 15), ignoringConflicts: false)
        guard case .saved(let event) = outcome else { return XCTFail("saved expected, got \(outcome)") }
        for (adapter, id) in [(w.a, "work-a"), (w.b, "work-b")] {
            let copies = await w.copies(adapter, id)
            XCTAssertEqual(copies.map(\.title), ["Занято"])
            XCTAssertEqual(copies.first?.notes, "")
            XCTAssertEqual(copies.first?.location, "")
            XCTAssertEqual(copies.first?.attendees, [])
            XCTAssertEqual(copies.first?.busyMarker?.sourceEventID, event.id)
            XCTAssertEqual(copies.first?.time, .timed(start: w.h.at(14), end: w.h.at(15), timeZone: nil))
        }
        let snapshot = try await w.h.service.snapshot(window: DateInterval(start: w.h.at(0), duration: 86400))
        XCTAssertEqual(
            snapshot.events.values.filter { $0.isBusyCopy && $0.collectionID == w.workA.id }.count, 1, "the copy is mirrored locally")
    }

    func testCallInWorkAppearsAsBusyInPersonalAndWorkB() async throws {
        let w = try await busyWorld(aEvents: [timed("Созвон A", 10, 11)])
        let personalCopies = try await w.h.store.liveEvents(collectionID: w.personal.id).filter(\.isBusyCopy)
        XCTAssertEqual(personalCopies.map(\.title), ["Занято"])
        let bCopies = await w.copies(w.b, "work-b")
        XCTAssertEqual(bCopies.count, 1)
        let aCopies = await w.copies(w.a, "work-a")
        XCTAssertTrue(aCopies.isEmpty, "no copy in its own calendar")
    }

    func testMovingOriginalMovesCopiesAndDeletingRemovesThem() async throws {
        let w = try await busyWorld()
        guard case .saved(let event) = try await w.h.service.create(w.draft(in: w.personal, 14, 15), ignoringConflicts: false) else {
            return XCTFail()
        }
        _ = try await w.h.service.move(
            eventID: event.id, occurrenceKey: nil, to: .timed(start: w.h.at(16), end: w.h.at(17), timeZone: nil), scope: .series,
            ignoringConflicts: false)
        let moved = await w.copies(w.a, "work-a")
        XCTAssertEqual(moved.map(\.time), [.timed(start: w.h.at(16), end: w.h.at(17), timeZone: nil)])
        try await w.h.service.delete(eventID: event.id, occurrenceKey: nil, scope: .series)
        let afterA = await w.copies(w.a, "work-a"), afterB = await w.copies(w.b, "work-b")
        XCTAssertTrue(afterA.isEmpty && afterB.isEmpty)
        let records = try await w.h.store.busyCopies(targetCollectionID: nil)
        XCTAssertTrue(records.isEmpty)
    }

    func testTamperedCopyIsRestoredOnNextPass() async throws {
        let w = try await busyWorld()
        _ = try await w.h.service.create(w.draft(in: w.personal, 14, 15), ignoringConflicts: false)
        let placed = await w.copies(w.a, "work-a")
        let copy = try XCTUnwrap(placed.first)
        await w.a.tamper(externalID: copy.externalID!, collectionExternalID: "work-a", shiftMinutes: 30)
        await w.h.service.sync(accountID: w.workA.accountID)
        let restored = await w.copies(w.a, "work-a")
        XCTAssertEqual(restored.map(\.time), [.timed(start: w.h.at(14), end: w.h.at(15), timeZone: nil)])
        await w.a.remove(externalID: copy.externalID!, collectionExternalID: "work-a")
        await w.h.service.sync(accountID: w.workA.accountID)
        let recreated = await w.copies(w.a, "work-a")
        XCTAssertEqual(recreated.count, 1, "a deleted copy comes back")
    }

    func testConflictReturnedBeforeWriteAndIgnoringWrites() async throws {
        let w = try await busyWorld(aEvents: [timed("Созвон A", 10, 11)])
        let outcome = try await w.h.service.create(w.draft(in: w.personal, 10.5, 11.5), ignoringConflicts: false)
        guard case .conflicts(let conflicts) = outcome else { return XCTFail("conflicts expected") }
        XCTAssertEqual(conflicts.count, 1)
        let none = try await w.h.store.liveEvents(collectionID: w.personal.id).filter { !$0.isBusyCopy }
        XCTAssertTrue(none.isEmpty, "nothing written before the answer")
        let forced = try await w.h.service.create(w.draft(in: w.personal, 10.5, 11.5), ignoringConflicts: true)
        guard case .saved = forced else { return XCTFail("saved expected") }
    }

    func testRespondDeclinedRemovesBusyAndCopies() async throws {
        var invite = timed("Совещание", 12, 13)
        invite.organizerEmail = "boss@x.test"
        invite.attendees = [
            .init(email: "boss@x.test", response: .accepted, isOrganizer: true),
            .init(email: "me@a.test", response: .needsAction, isSelf: true),
        ]
        let w = try await busyWorld(aEvents: [invite])
        let before = await w.copies(w.b, "work-b")
        XCTAssertEqual(before.count, 1)
        let stored = try await w.h.store.liveEvents(collectionID: w.workA.id).first { $0.title == "Совещание" }!
        try await w.h.service.respond(eventID: stored.id, .declined)
        let after = await w.copies(w.b, "work-b")
        XCTAssertTrue(after.isEmpty)
        let server = await w.a.externalEvents(collectionExternalID: "work-a").first { $0.title == "Совещание" }
        XCTAssertEqual(server?.selfResponse, .declined)
    }

    func testUnknownCopyIsAdoptedNotDuplicated() async throws {
        let w = try await busyWorld()
        await w.b.failNext(.unknownOutcome(stage: "copy"))
        _ = try await w.h.service.create(w.draft(in: w.personal, 14, 15), ignoringConflicts: false)
        let open = try await w.h.store.openAttempts()
        XCTAssertEqual(open.map(\.state), [.unknown])
        await w.h.service.sync(accountID: w.workB.accountID)
        let copies = await w.copies(w.b, "work-b")
        XCTAssertEqual(copies.count, 1)
        let stillOpen = try await w.h.store.openAttempts()
        XCTAssertTrue(stillOpen.isEmpty)
        let records = try await w.h.store.busyCopies(targetCollectionID: w.workB.id)
        XCTAssertEqual(records.map(\.state), [.placed])
    }

    func testUnknownInviteWaitsForCheckAndFindsByUID() async throws {
        let w = try await busyWorld()
        await w.a.failNext(.unknownOutcome(stage: "create"))
        let outcome = try await w.h.service.create(
            w.draft(in: w.workA, 9, 10, title: "Созвон", attendees: ["bob@x.test"]), ignoringConflicts: false)
        guard case .attemptOpen(let attempt) = outcome else { return XCTFail("attempt expected, got \(outcome)") }
        XCTAssertEqual(attempt.state, .unknown)
        let sent = await w.a.sentInvitations
        XCTAssertEqual(sent.count, 1)
        let state = try await w.h.service.check(attemptID: attempt.id)
        XCTAssertEqual(state, .confirmed)
        let resent = await w.a.sentInvitations
        XCTAssertEqual(resent.count, 1, "never sent twice")
        let event = try await w.h.store.event(id: attempt.eventID!)
        XCTAssertNotNil(event?.externalID)
    }

    func testWritesCappedPerPass() async throws {
        let w = try await busyWorld()
        var draft = w.draft(in: w.personal, 20, 20.5)
        draft.recurrence = CalendarRecurrence(rrule: "FREQ=DAILY")
        _ = try await w.h.service.create(draft, ignoringConflicts: true)
        let first = await w.copies(w.a, "work-a")
        XCTAssertEqual(first.count, 50)
        await w.h.service.reconcileBusy(read: [])
        let second = await w.copies(w.a, "work-a")
        XCTAssertEqual(second.count, 90)
    }

    func testGroupPreviewCountsWithoutWriting() async throws {
        let a = synthetic("work-a"), h = try await calendarHarness(["Работа A": a])
        _ = try await h.service.addCalDAVAccount(name: "Работа A", server: URL(string: "https://a.test")!, login: "me", password: "p")
        let personal = try await h.store.collections().first { $0.externalID == "local" }!
        _ = try await h.service.create(
            CalendarDraft(collectionID: personal.id, title: "Стоматолог", time: .timed(start: h.at(14), end: h.at(15), timeZone: nil)),
            ignoringConflicts: false)
        let group = CalendarGroup(name: "Все")
        var proposed = try await h.store.collections()
        for index in proposed.indices { proposed[index].groupIDs = [group.id] }
        let preview = try await h.service.previewGroupChange(collections: proposed, groups: [group])
        let workA = proposed.first { $0.externalID == "work-a" }!
        XCTAssertEqual(preview.create[workA.id], 1)
        XCTAssertTrue(preview.remove.isEmpty)
        let copies = await a.externalEvents(collectionExternalID: "work-a")
        XCTAssertTrue(copies.isEmpty, "a preview writes nothing")
        let stored = try await h.store.collections()
        XCTAssertTrue(stored.allSatisfy { $0.groupIDs.isEmpty })
    }

    func testBusyCopyCannotBeEdited() async throws {
        let w = try await busyWorld(aEvents: [timed("Созвон A", 10, 11)])
        let live = try await w.h.store.liveEvents(collectionID: w.personal.id)
        let copy = try XCTUnwrap(live.first(where: \.isBusyCopy))
        do {
            _ = try await w.h.service.move(
                eventID: copy.id, occurrenceKey: nil, to: .timed(start: w.h.at(12), end: w.h.at(13), timeZone: nil), scope: .series,
                ignoringConflicts: true)
            XCTFail("a busy copy must not move")
        } catch { XCTAssertEqual(error as? CalendarFailure, .invalidInput("busy copy")) }
    }

    func testLocalCalendarRefusesAttendees() async throws {
        let w = try await busyWorld()
        do {
            _ = try await w.h.service.create(w.draft(in: w.personal, 9, 10, attendees: ["bob@x.test"]), ignoringConflicts: true)
            XCTFail("local calendar must refuse attendees")
        } catch { XCTAssertEqual(error as? CalendarFailure, .invalidInput("local calendar has no attendees")) }
    }

    func testRevokedMidPassKeepsConfirmedWrites() async throws {
        let w = try await busyWorld()
        await w.a.failNext(.rejected(code: 401, stage: "copy"))
        _ = try await w.h.service.create(w.draft(in: w.personal, 14, 15), ignoringConflicts: false)
        let bCopies = await w.copies(w.b, "work-b")
        XCTAssertEqual(bCopies.count, 1)
        let accountA = try await w.h.store.accounts().first { $0.id == w.workA.accountID }
        XCTAssertEqual(accountA?.state, .needsSignIn)
        let snapshot = try await w.h.service.snapshot(window: DateInterval(start: w.h.at(0), duration: 86400))
        XCTAssertTrue(snapshot.staleCollectionIDs.contains(w.workA.id))
    }

    func testDeleteOneOccurrenceOfLocalSeriesKeepsTheRest() async throws {
        let w = try await busyWorld()
        var draft = w.draft(in: w.personal, 9, 10, title: "Зарядка")
        draft.recurrence = CalendarRecurrence(rrule: "FREQ=DAILY;COUNT=3")
        guard case .saved(let series) = try await w.h.service.create(draft, ignoringConflicts: true) else { return XCTFail() }
        try await w.h.service.delete(eventID: series.id, occurrenceKey: w.h.at(33), scope: .occurrence)
        let snapshot = try await w.h.service.snapshot(window: DateInterval(start: w.h.at(0), duration: 5 * 86400))
        let left = snapshot.occurrences.filter { snapshot.events[$0.eventID]?.title == "Зарядка" }
        XCTAssertEqual(left.map(\.start), [w.h.at(9), w.h.at(57)])
        let copies = await w.copies(w.a, "work-a")
        XCTAssertEqual(copies.count, 2)
    }
}

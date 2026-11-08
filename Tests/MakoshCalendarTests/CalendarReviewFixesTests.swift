import Foundation
import XCTest
@testable import MakoshCalendar

/// Regressions found by the whole-branch review.
final class CalendarReviewFixesTests: XCTestCase {
    private func count(_ w: BusyWorld, _ state: String) throws -> Int {
        Int(try w.h.db.execute("SELECT count(*) FROM \"\(w.h.db.schema)\".calendar_attempts WHERE state = '\(state)'")[0][0]) ?? -1
    }

    func testConcurrentPassesNeverDuplicateOrRejectCopies() async throws {
        let w = try await busyWorld()
        await w.a.setWriteDelay(.milliseconds(40))
        await w.b.setWriteDelay(.milliseconds(40))
        _ = try await w.h.service.create(w.draft(in: w.personal, 14, 15), ignoringConflicts: false)
        async let one: Void = w.h.service.sync(accountID: w.workA.accountID)
        async let two: Void = w.h.service.sync(accountID: w.workB.accountID)
        async let all: Void = w.h.service.syncAll()
        _ = await (one, two, all)
        await w.h.service.settled()
        let aCopies = await w.copies(w.a, "work-a"), bCopies = await w.copies(w.b, "work-b")
        XCTAssertEqual(aCopies.count, 1)
        XCTAssertEqual(bCopies.count, 1)
        XCTAssertEqual(try count(w, "rejected"), 0)
        XCTAssertEqual(try count(w, "unknown"), 0)
    }

    func testSyncDoesNotUndoAccountChangesMadeDuringIt() async throws {
        let w = try await busyWorld()
        await w.a.setWriteDelay(.milliseconds(80))
        async let pass: Void = w.h.service.sync(accountID: w.workA.accountID)
        try await Task.sleep(for: .milliseconds(20))
        var renamed = try await w.h.store.accounts().first { $0.id == w.workA.accountID }!
        renamed.name = "Работа A (новое имя)"
        try await w.h.service.updateAccount(renamed)
        await pass
        let after = try await w.h.store.accounts().first { $0.id == w.workA.accountID }
        XCTAssertEqual(after?.name, "Работа A (новое имя)")
    }

    func testDisconnectDuringPassStaysDisconnected() async throws {
        let w = try await busyWorld()
        await w.b.setWriteDelay(.milliseconds(80))
        async let pass: Void = w.h.service.sync(accountID: w.workB.accountID)
        try await Task.sleep(for: .milliseconds(20))
        await w.b.setWriteDelay(.zero)
        try await w.h.service.disconnect(accountID: w.workB.accountID)
        await pass
        let after = try await w.h.store.accounts().first { $0.id == w.workB.accountID }
        XCTAssertEqual(after?.state, .disabled)
    }

    func testDisconnectRemovesEveryCopyBeyondOnePass() async throws {
        let w = try await busyWorld()
        var draft = w.draft(in: w.personal, 20, 20.5)
        draft.recurrence = CalendarRecurrence(rrule: "FREQ=DAILY")
        _ = try await w.h.service.create(draft, ignoringConflicts: true)
        await w.h.service.settled()
        await w.h.service.reconcileBusy(read: [])
        let placed = await w.copies(w.a, "work-a")
        XCTAssertEqual(placed.count, 90)
        try await w.h.service.disconnect(accountID: w.workA.accountID)
        let left = await w.a.externalEvents(collectionExternalID: "work-a").filter { $0.busyMarker != nil }
        XCTAssertTrue(left.isEmpty, "\(left.count) copies stranded")
    }

    func testFullReadKeepsEndedSeriesButDropsLiveAbsentOnes() async throws {
        var ended = timed("Курс", -200 * 24 + 9, -200 * 24 + 10)
        ended.recurrence = CalendarRecurrence(rrule: "FREQ=DAILY;COUNT=3")
        var live = timed("Йога", 9, 10)
        live.recurrence = CalendarRecurrence(rrule: "FREQ=WEEKLY")
        let a = synthetic("work-a", events: [ended, live])
        let h = try await calendarHarness(["Работа A": a])
        let account = try await h.service.addCalDAVAccount(
            name: "Работа A", server: URL(string: "https://a.test")!, login: "me", password: "p")
        let collection = try await h.store.collections().first { $0.accountID == account.id }!
        for event in await a.externalEvents(collectionExternalID: "work-a") {
            await a.remove(externalID: event.externalID!, collectionExternalID: "work-a")
        }
        try await h.store.saveCursor(nil, collectionID: collection.id)
        await h.service.sync(accountID: account.id)
        let titles = try await h.store.liveEvents(collectionID: collection.id).map(\.title)
        XCTAssertEqual(titles, ["Курс"], "an ended series absent from a full read is history, a live one is gone")
    }

    func testBrokenCalendarDoesNotBlockOthersAndNewCalendarsAppear() async throws {
        let a = CalendarSyntheticAdapter(
            collections: [
                RemoteCollection(externalID: "gone", name: "Удалённый", color: nil, access: .write),
                RemoteCollection(externalID: "work-a", name: "Работа A", color: nil, access: .write),
            ], events: [:])
        let h = try await calendarHarness(["Работа A": a])
        let account = try await h.service.addCalDAVAccount(
            name: "Работа A", server: URL(string: "https://a.test")!, login: "me", password: "p")
        await a.breakCollection("gone", with: .rejected(code: 404, stage: "events"))
        _ = await a.addRemote(timed("Созвон", 10, 11), collectionExternalID: "work-a")
        await h.service.sync(accountID: account.id)
        let collection = try await h.store.collections().first { $0.externalID == "work-a" }!
        let events = try await h.store.liveEvents(collectionID: collection.id)
        XCTAssertEqual(events.map(\.title), ["Созвон"])
        let state = try await h.store.accounts().first { $0.id == account.id }?.state
        XCTAssertEqual(state, .connected)
        await a.addCollection(RemoteCollection(externalID: "shared", name: "Общий", color: nil, access: .read))
        h.clock.set(h.at(2))
        await h.service.sync(accountID: account.id)
        let names = try await h.store.collections().filter { $0.accountID == account.id }.map(\.externalID)
        XCTAssertTrue(names.contains("shared"))
    }

    func testConflictCheckOfOldSeriesLooksAhead() async throws {
        let w = try await busyWorld(aEvents: [timed("Старое", -300 * 24 + 9, -300 * 24 + 10)])
        var draft = w.draft(in: w.personal, -300 * 24 + 9, -300 * 24 + 10, title: "Зарядка")
        draft.recurrence = CalendarRecurrence(rrule: "FREQ=DAILY")
        guard case .saved(let series) = try await w.h.service.create(draft, ignoringConflicts: true) else { return XCTFail() }
        draft.title = "Утренняя зарядка"
        let renamed = try await w.h.service.update(
            eventID: series.id, occurrenceKey: nil, draft: draft, scope: .series, ignoringConflicts: false)
        guard case .saved = renamed else { return XCTFail("a past overlap must not block an edit: \(renamed)") }
        _ = await w.a.addRemote(timed("Будущее", 48 + 9, 48 + 10), collectionExternalID: "work-a")
        await w.h.service.sync(accountID: w.workA.accountID)
        draft.title = "Зарядка 2"
        let blocked = try await w.h.service.update(
            eventID: series.id, occurrenceKey: nil, draft: draft, scope: .series, ignoringConflicts: false)
        guard case .conflicts(let found) = blocked else { return XCTFail("a future overlap must be found") }
        XCTAssertTrue(found.allSatisfy { $0.start > w.h.at(0) })
    }

    func testEditWhileCreateIsUnknownChangesNothing() async throws {
        let w = try await busyWorld()
        await w.a.failNext(.unknownOutcome(stage: "create"))
        guard
            case .attemptOpen(let attempt) = try await w.h.service.create(
                w.draft(in: w.workA, 9, 10, title: "Созвон", attendees: ["bob@x.test"]), ignoringConflicts: false)
        else { return XCTFail() }
        var draft = w.draft(in: w.workA, 9, 10, title: "Переименовано", attendees: ["bob@x.test"])
        draft.collectionID = w.workA.id
        do {
            _ = try await w.h.service.update(
                eventID: attempt.eventID!, occurrenceKey: nil, draft: draft, scope: .series, ignoringConflicts: true)
            XCTFail("an edit must wait for the open attempt")
        } catch { XCTAssertEqual(error as? CalendarFailure, .invalidInput("attempt open")) }
        let event = try await w.h.store.event(id: attempt.eventID!)
        XCTAssertEqual(event?.title, "Созвон")
    }

    func testUnknownUpdateThatNeverLandedIsRejectedOnCheck() async throws {
        let w = try await busyWorld()
        guard case .saved(let event) = try await w.h.service.create(w.draft(in: w.workA, 9, 10, title: "Созвон"), ignoringConflicts: false)
        else { return XCTFail() }
        await w.a.failNextWithoutApplying(.unknownOutcome(stage: "update"))
        var draft = w.draft(in: w.workA, 9, 10, title: "Новое название")
        draft.collectionID = w.workA.id
        guard
            case .attemptOpen(let attempt) = try await w.h.service.update(
                eventID: event.id, occurrenceKey: nil, draft: draft, scope: .series, ignoringConflicts: true)
        else { return XCTFail() }
        let state = try await w.h.service.check(attemptID: attempt.id)
        XCTAssertEqual(state, .rejected, "the server still has the old version")
        let after = try await w.h.store.event(id: event.id)
        XCTAssertEqual(after?.title, "Созвон")
    }

    func testStrayFromAnotherInstallIsKept() async throws {
        let w = try await busyWorld()
        var foreign = timed("Занято", 30, 31)
        foreign.busyMarker = CalendarBusyMarker(sourceEventID: UUID(), occurrenceStart: w.h.at(30))
        _ = await w.a.addRemote(foreign, collectionExternalID: "work-a")
        await w.h.service.sync(accountID: w.workA.accountID)
        await w.h.service.settled()
        let copies = await w.a.externalEvents(collectionExternalID: "work-a").filter { $0.busyMarker != nil }
        XCTAssertEqual(copies.count, 1, "a copy placed by another Makosh install is not ours to delete")
    }

    func testRecurringSlotKeepsLocalTimeZone() async throws {
        let w = try await busyWorld()
        let slot = CalendarSlotValue(
            id: UUID(), taskID: nil, title: "Обед", start: w.h.at(12.5), end: w.h.at(13), rrule: "FREQ=DAILY", collectionID: nil)
        try await w.h.service.syncSlots(
            day: DateInterval(start: w.h.at(0), duration: 86400), slots: [slot], defaultCollectionID: w.personal.id)
        let event = try await w.h.store.liveEvents(collectionID: w.personal.id).first { $0.uid == CalendarSlotValue.uid(slot.id) }
        guard case .timed(_, _, let zone)? = event?.time else { return XCTFail() }
        XCTAssertEqual(zone, TimeZone.current.identifier)
    }
}

@MainActor final class CalendarReviewFixesModelTests: XCTestCase {
    func testSlotsDefaultToTheLocalCalendar() async throws {
        let w = try await busyWorld()
        let model = CalendarWorkspaceModel(service: w.h.service, now: { w.h.clock.get() })
        await model.create(w.draft(in: w.workA, 8, 9))
        XCTAssertEqual(model.defaultCollectionID, w.workA.id)
        XCTAssertEqual(model.slotCollectionID, w.personal.id, "planner slots never follow the last used work calendar")
    }
}

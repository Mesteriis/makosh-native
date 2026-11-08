import Foundation
import XCTest
@testable import MakoshCalendar

final class FakeTaskFeed: CalendarTaskFeed, @unchecked Sendable {
    var items: [CalendarTaskItem]
    var estimates: [UUID: Int] = [:]
    init(_ items: [CalendarTaskItem]) { self.items = items }
    func tasks(agenda: CalendarTaskAgenda) async -> [CalendarTaskItem] { items }
    func dueMarks(in interval: DateInterval) async -> [Date: [CalendarTaskItem]] { [:] }
    func setEstimate(taskID: UUID, minutes: Int) async { estimates[taskID] = minutes }
}

@MainActor
final class CalendarWorkspaceModelTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func model(_ w: BusyWorld, feed: FakeTaskFeed? = nil) async -> CalendarWorkspaceModel {
        let model = CalendarWorkspaceModel(service: w.h.service, calendar: utc, now: { w.h.clock.get() })
        model.taskFeed = feed
        model.period = CalendarPeriod(mode: .week, anchor: w.h.at(0))
        await model.refresh()
        return model
    }

    private func invite(_ from: Double, _ to: Double) -> CalendarEvent {
        var event = timed("Совещание", from, to)
        event.organizerEmail = "boss@x.test"
        event.attendees = [
            .init(email: "boss@x.test", response: .accepted, isOrganizer: true),
            .init(email: "me@a.test", response: .needsAction, isSelf: true),
        ]
        return event
    }

    private func titles(_ items: [CalendarGridItem], _ model: CalendarWorkspaceModel) -> [String] {
        items.compactMap { model.snapshot?.events[$0.occurrence.eventID]?.title }.sorted()
    }

    func testSummaryHidesBusyCopiesCalendarViewShowsThem() async throws {
        let w = try await busyWorld(aEvents: [timed("Созвон A", 10, 11)])
        let model = await model(w)
        XCTAssertEqual(titles(model.visibleOccurrences(day: w.h.at(0)), model), ["Созвон A"])
        model.select(collectionID: w.personal.id)
        XCTAssertEqual(titles(model.visibleOccurrences(day: w.h.at(0)), model), ["Занято"])
        model.select(collectionID: w.workA.id)
        XCTAssertEqual(titles(model.visibleOccurrences(day: w.h.at(0)), model), ["Созвон A"])
    }

    func testWorkingHoursOnlyInCalendarView() async throws {
        let w = try await busyWorld()
        var account = try await w.h.store.accounts().first { $0.id == w.workA.accountID }!
        account.workingHours = CalendarWorkingHours(days: [1: [540...900]])
        try await w.h.store.saveAccount(account)
        let model = await model(w)
        let monday = w.h.at(24)
        XCTAssertEqual(model.workingHours(day: monday), [])
        model.select(collectionID: w.workA.id)
        XCTAssertEqual(model.workingHours(day: monday), [540...900])
        XCTAssertEqual(model.workingHours(day: w.h.at(0)), [], "Sunday has no hours")
    }

    func testDropOntoBusyShiftsToFreeSlot() async throws {
        let w = try await busyWorld(aEvents: [timed("Созвон A", 10, 11)])
        let model = await model(w)
        await model.dropTask(CalendarTaskItem(id: UUID(), title: "Отчёт", estimateMinutes: 60, due: nil, overdue: false), at: w.h.at(10.1))
        XCTAssertNil(model.conflict)
        let created = try await w.h.store.liveEvents(collectionID: w.personal.id).first { $0.title == "Отчёт" }
        XCTAssertEqual(created?.time, .timed(start: w.h.at(11), end: w.h.at(12), timeZone: nil))
        XCTAssertNotNil(created?.taskID)
    }

    func testDropWithNoRoomRaisesConflict() async throws {
        let w = try await busyWorld(aEvents: [timed("Весь день занят", 0, 24)])
        let model = await model(w)
        await model.dropTask(CalendarTaskItem(id: UUID(), title: "Отчёт", estimateMinutes: nil, due: nil, overdue: false), at: w.h.at(10))
        XCTAssertEqual(model.conflict?.conflicts.count, 1)
        let none = try await w.h.store.liveEvents(collectionID: w.personal.id).filter { $0.title == "Отчёт" }
        XCTAssertTrue(none.isEmpty)
        await model.resolveConflict(.writeAnyway)
        XCTAssertNil(model.conflict)
        let written = try await w.h.store.liveEvents(collectionID: w.personal.id).first { $0.title == "Отчёт" }
        XCTAssertEqual(written?.time, .timed(start: w.h.at(10), end: w.h.at(11), timeZone: nil))
    }

    func testPickTimeRechecksAndWrites() async throws {
        let w = try await busyWorld(aEvents: [timed("Созвон A", 10, 11)])
        let model = await model(w)
        await model.create(w.draft(in: w.personal, 10, 11))
        let suggestion = try XCTUnwrap(model.conflict?.suggestion)
        XCTAssertEqual(suggestion, w.h.at(11))
        await model.resolveConflict(.pickTime(suggestion))
        XCTAssertNil(model.conflict)
        let written = try await w.h.store.liveEvents(collectionID: w.personal.id).first { $0.title == "Стоматолог" }
        XCTAssertEqual(written?.time, .timed(start: w.h.at(11), end: w.h.at(12), timeZone: nil))
    }

    func testDeclineRespondsThenWrites() async throws {
        let w = try await busyWorld(aEvents: [invite(10, 11)])
        let model = await model(w)
        await model.create(w.draft(in: w.personal, 10, 11))
        let conflict = try XCTUnwrap(model.conflict?.conflicts.first)
        XCTAssertTrue(conflict.isInvitation)
        await model.resolveConflict(.decline(conflict))
        XCTAssertNil(model.conflict)
        let written = try await w.h.store.liveEvents(collectionID: w.personal.id).first { $0.title == "Стоматолог" }
        XCTAssertNotNil(written)
        let server = await w.a.externalEvents(collectionExternalID: "work-a").first { $0.title == "Совещание" }
        XCTAssertEqual(server?.selfResponse, .declined)
    }

    func testWriteToOrganizerCallsClosure() async throws {
        let w = try await busyWorld(aEvents: [invite(10, 11)])
        let model = await model(w)
        var mailed: (String, String?)?
        model.writeToOrganizer = { mailed = ($0, $1) }
        await model.create(w.draft(in: w.personal, 10, 11))
        let conflict = try XCTUnwrap(model.conflict?.conflicts.first)
        await model.resolveConflict(.writeToOrganizer(conflict))
        XCTAssertEqual(mailed?.0, "boss@x.test")
        XCTAssertEqual(mailed?.1, "Совещание")
    }

    func testGroupChangeNeedsConfirmation() async throws {
        let w = try await busyWorld()
        let model = await model(w)
        var collections = try await w.h.store.collections()
        for index in collections.indices { collections[index].groupIDs = [] }
        await model.stage(collections: collections, groups: [w.group])
        XCTAssertNotNil(model.groupPreview)
        let unchanged = try await w.h.store.collections()
        XCTAssertTrue(unchanged.allSatisfy { $0.groupIDs == [w.group.id] })
        await model.confirmGroupChange()
        XCTAssertNil(model.groupPreview)
        let changed = try await w.h.store.collections()
        XCTAssertTrue(changed.allSatisfy { $0.groupIDs.isEmpty })
    }

    func testLastCollectionRemembered() async throws {
        let w = try await busyWorld()
        let model = await model(w)
        XCTAssertEqual(model.defaultCollectionID, w.personal.id)
        await model.create(w.draft(in: w.workA, 8, 9))
        XCTAssertEqual(model.defaultCollectionID, w.workA.id)
    }

    func testUndoMoveWritesPreviousTime() async throws {
        let w = try await busyWorld()
        let model = await model(w)
        await model.create(w.draft(in: w.personal, 14, 15))
        let event = try await w.h.store.liveEvents(collectionID: w.personal.id).first { $0.title == "Стоматолог" }!
        await model.move(
            eventID: event.id, occurrenceKey: nil, to: .timed(start: w.h.at(16), end: w.h.at(17), timeZone: nil), scope: .series)
        await model.undoLastMove()
        XCTAssertFalse(model.undoNeedsConfirmation)
        let back = try await w.h.store.event(id: event.id)
        XCTAssertEqual(back?.time, .timed(start: w.h.at(14), end: w.h.at(15), timeZone: nil))
    }

    func testUndoWithAttendeesAsksFirst() async throws {
        let w = try await busyWorld()
        let model = await model(w)
        await model.create(w.draft(in: w.workA, 14, 15, title: "Созвон", attendees: ["bob@x.test"]))
        let event = try await w.h.store.liveEvents(collectionID: w.workA.id).first { $0.title == "Созвон" }!
        await model.move(
            eventID: event.id, occurrenceKey: nil, to: .timed(start: w.h.at(16), end: w.h.at(17), timeZone: nil), scope: .series)
        await model.undoLastMove()
        XCTAssertTrue(model.undoNeedsConfirmation)
        let moved = try await w.h.store.event(id: event.id)
        XCTAssertEqual(moved?.time, .timed(start: w.h.at(16), end: w.h.at(17), timeZone: nil))
        await model.confirmUndo()
        let back = try await w.h.store.event(id: event.id)
        XCTAssertEqual(back?.time, .timed(start: w.h.at(14), end: w.h.at(15), timeZone: nil))
    }

    func testTasksLoadFromFeed() async throws {
        let w = try await busyWorld()
        let feed = FakeTaskFeed([CalendarTaskItem(id: UUID(), title: "Ревью", estimateMinutes: 30, due: nil, overdue: false)])
        let model = await model(w, feed: feed)
        XCTAssertEqual(model.tasks.map(\.title), ["Ревью"])
    }
}

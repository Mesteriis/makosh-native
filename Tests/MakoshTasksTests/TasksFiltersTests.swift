import Foundation
import XCTest
@testable import MakoshTasks

final class TasksFiltersTests: XCTestCase {
    func testToggleSameValueClears() {
        var filters = TasksFilters()
        filters.toggle(status: .active)
        XCTAssertEqual(filters.status, .active)
        filters.toggle(status: .active)
        XCTAssertNil(filters.status)
        filters.toggle(agenda: .today)
        filters.toggle(list: "Работа")
        filters.toggle(tag: "релиз")
        filters.toggle(persona: "Боб")
        filters.toggle(flow: "Релиз")
        XCTAssertTrue(filters.isFiltering)
        XCTAssertEqual(filters.chips.map(\.title), ["Сегодня", "Работа", "#релиз", "Боб", "Релиз"])
        filters.toggle(agenda: .week)
        XCTAssertEqual(filters.agenda, .week, "another value replaces")
        filters.groupByFlow = true
        filters.clearFilters()
        XCTAssertFalse(filters.isFiltering)
        XCTAssertTrue(filters.groupByFlow, "a display preference survives clearing")
        XCTAssertNil(filters.list)
    }

    func testDayAndAgendaExcludeEachOther() {
        var filters = TasksFilters()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        filters.toggle(agenda: .today)
        filters.select(day: day)
        XCTAssertNil(filters.agenda)
        XCTAssertEqual(filters.day, day)
        filters.toggle(agenda: .month)
        XCTAssertNil(filters.day)
        filters.select(day: day)
        filters.select(day: day)
        XCTAssertNil(filters.day, "the same day again clears it")
        filters.actualOnly = true
        XCTAssertTrue(filters.isFiltering, "«only actual» counts as filtering")
    }

    func testSnapshotRoundTrip() {
        var filters = TasksFilters()
        filters.status = .done
        filters.list = "Работа"
        filters.day = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 20))
        filters.actualOnly = true
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let snapshot = filters.snapshot(calendar: calendar)
        XCTAssertEqual(snapshot.status, "done")
        XCTAssertEqual(snapshot.day, "2026-11-20")
        XCTAssertEqual(TasksFilters(snapshot: snapshot, calendar: calendar), filters)
    }

    func testSortToggleCycles() {
        var state: TasksSortState? = nil
        state = TasksSortState.toggled(state, field: .priority)
        XCTAssertEqual(state, TasksSortState(field: .priority, descending: false))
        state = TasksSortState.toggled(state, field: .priority)
        XCTAssertEqual(state, TasksSortState(field: .priority, descending: true))
        state = TasksSortState.toggled(state, field: .priority)
        XCTAssertNil(state)
        state = TasksSortState.toggled(TasksSortState(field: .priority, descending: true), field: .due)
        XCTAssertEqual(state, TasksSortState(field: .due, descending: false), "another field restarts ascending")
    }

    func testKeyboardLayoutSwap() {
        XCTAssertEqual(KeyboardLayout.swapped("ghbdtn"), "привет")
        XCTAssertEqual(KeyboardLayout.swapped("привет"), "ghbdtn")
        XCTAssertEqual(KeyboardLayout.swapped("123 !"), "123 !")
    }

    func testTaskReferenceNormalize() {
        XCTAssertEqual(TaskReference.normalize("to:7k3mz"), "7K3MZ")
        XCTAssertEqual(TaskReference.normalize("to:7K3ML"), "7K3M1")
        XCTAssertEqual(TaskReference.normalize("O0II"), "0011")
        XCTAssertNil(TaskReference.normalize("hello!"))
        XCTAssertNil(TaskReference.normalize("to:ab"))
        XCTAssertEqual(TaskReference.text(code: "7K3MZ", title: "Счёт"), "to:7K3MZ Счёт")
    }
}

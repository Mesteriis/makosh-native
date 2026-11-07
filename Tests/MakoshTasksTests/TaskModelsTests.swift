import Foundation
import XCTest
@testable import MakoshTasks

final class TaskModelsTests: XCTestCase {
    func testCodeIsFiveCrockfordCharacters() {
        let code = TaskCode.make(from: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        XCTAssertEqual(code.count, 5)
        XCTAssertTrue(code.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        let other = TaskCode.make(from: UUID(uuidString: "ffffffff-0000-0000-0000-000000000000")!)
        XCTAssertNotEqual(code, other, "different leading bits give different codes")
    }

    func testStatusCycleOrder() { XCTAssertEqual(TaskStatus.allCases, [.inbox, .active, .done, .cancelled]) }

    private func legacyTask(notes: String) -> String {
        """
        {"id":"7A5B0ABD-0000-4000-8000-000000000001","code":"ABCDE","title":"x","status":"inbox","priority":4,"tags":[],\
        "postponed":0,"dependsOn":[],"notes":\(notes),"createdAt":"2026-11-07T10:00:00.000Z",\
        "updatedAt":"2026-11-07T10:00:00.000Z","revision":1}
        """
    }

    func testLegacyNotesStringDecodesAsOneNote() throws {
        let task = try TaskStore.makeDecoder().decode(Task.self, from: Data(legacyTask(notes: "\"старая заметка\"").utf8))
        XCTAssertEqual(task.notes.map(\.content), ["старая заметка"])
        XCTAssertEqual(task.notes.first?.createdAt, task.createdAt)
        XCTAssertEqual(task.personas, [])
        XCTAssertNil(task.recurrence)
        XCTAssertNil(task.flowID)
        XCTAssertEqual(task.notesText, "старая заметка")
    }

    func testEmptyLegacyNotesDecodeAsNoNotes() throws {
        let task = try TaskStore.makeDecoder().decode(Task.self, from: Data(legacyTask(notes: "\"\"").utf8))
        XCTAssertEqual(task.notes, [])
    }

    func testNotesListRoundTrips() throws {
        let note = TaskNote(content: "первая", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let task = Task(title: "x", personas: ["Боб"], recurrence: "weekly", flowID: "Релиз", notes: [note])
        let data = try TaskStore.makeEncoder().encode(task)
        let decoded = try TaskStore.makeDecoder().decode(Task.self, from: data)
        XCTAssertEqual(decoded.notes, [note])
        XCTAssertEqual(decoded.personas, ["Боб"])
        XCTAssertEqual(decoded.recurrence, "weekly")
        XCTAssertEqual(decoded.flowID, "Релиз")
        XCTAssertEqual(Task(title: "y", notes: [note, TaskNote(content: "вторая")]).notesText, "первая\n\nвторая")
    }

    func testLegacyPreferencesDecode() throws {
        let json = #"{"sort":"due","filter":"status:done","showCompleted":false}"#
        let value = try JSONDecoder().decode(TaskPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(value.sort, .due)
        XCTAssertFalse(value.sortDescending)
        XCTAssertEqual(value.filters.status, "done")
        XCTAssertNil(value.filters.agenda)
        XCTAssertTrue(value.filters.actualOnly)
        XCTAssertEqual(value.plannerDayStart, 9)
        XCTAssertEqual(value.plannerDayEnd, 17)
        XCTAssertEqual(value.plannerStep, 30)
        XCTAssertEqual(value.focus.presets, [15, 30, 45, 60])
        XCTAssertEqual(value.focus.breakMinutes, 5)
        XCTAssertEqual(value.focus.modules, [.timer, .presets, .controls, .waiting])
        XCTAssertEqual(value.dateFormat, .dmy)
        XCTAssertEqual(value.firstWeekday, 2)
        XCTAssertEqual(value.plannerWidthPercent, 40)
        let agenda = try JSONDecoder().decode(TaskPreferences.self, from: Data(#"{"filter":"overdue"}"#.utf8))
        XCTAssertEqual(agenda.filters.agenda, "overdue")
        XCTAssertNil(agenda.sort)
        let list = try JSONDecoder().decode(TaskPreferences.self, from: Data(#"{"filter":"list:Работа"}"#.utf8))
        XCTAssertEqual(list.filters.list, "Работа")
    }

    func testPreferencesV2RoundTrip() throws {
        var value = TaskPreferences()
        value.filters.tag = "релиз"
        value.filters.day = "2026-11-20"
        value.sort = .priority
        value.sortDescending = true
        value.condense = true
        value.showPlanner = true
        value.collapsedSections = ["hotkeys", "tags"]
        value.focus.enabled = true
        value.focus.modules.insert(.clock)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(TaskPreferences.self, from: data), value)
    }
}

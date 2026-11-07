import Foundation
import XCTest
@testable import MakoshTasks

final class TaskSelectionTests: XCTestCase {
    private let ids = (0..<6).map { _ in UUID() }

    func testClickShiftAndCommandBuildSelection() {
        var selection = TaskSelection()
        selection.click(index: 1, id: ids[1], shift: false, command: false, visible: ids)
        XCTAssertEqual(selection.selected, [ids[1]])
        XCTAssertEqual(selection.cursor, 1)
        selection.click(index: 3, id: ids[3], shift: true, command: false, visible: ids)
        XCTAssertEqual(selection.selected, [ids[1], ids[2], ids[3]])
        XCTAssertEqual(selection.cursor, 3)
        selection.click(index: 2, id: ids[2], shift: false, command: true, visible: ids)
        XCTAssertEqual(selection.selected, [ids[1], ids[3]], "command-click toggles one row")
        XCTAssertEqual(selection.cursor, 2)
        selection.click(index: 5, id: ids[5], shift: false, command: true, visible: ids)
        XCTAssertEqual(selection.selected, [ids[1], ids[3], ids[5]])
    }

    func testArrowsMoveAndShiftExtendsFromAnchor() {
        var selection = TaskSelection()
        selection.move(by: 1, extend: false, visible: ids)
        XCTAssertEqual(selection.cursor, 0, "the first move lands on the first row")
        XCTAssertEqual(selection.selected, [ids[0]])
        selection.move(by: 1, extend: false, visible: ids)
        selection.move(by: 1, extend: false, visible: ids)
        XCTAssertEqual(selection.cursor, 2)
        selection.move(by: -1, extend: true, visible: ids)
        XCTAssertEqual(selection.selected, [ids[1], ids[2]], "shift extends from the anchor at 2")
        XCTAssertEqual(selection.cursor, 1)
        selection.move(by: -5, extend: false, visible: ids)
        XCTAssertEqual(selection.cursor, 0, "clamped at the start")
        selection.jump(toStart: false, extend: true, visible: ids)
        XCTAssertEqual(selection.selected, Set(ids), "home/end with shift covers the range")
        XCTAssertEqual(selection.cursor, 5)
        selection.selectAll(visible: Array(ids.prefix(3)))
        XCTAssertEqual(selection.selected, Set(ids.prefix(3)))
    }

    func testClampDropsHiddenAndKeepsCursorInRange() {
        var selection = TaskSelection()
        selection.selectAll(visible: ids)
        selection.cursor = 5
        selection.clamp(to: Array(ids.prefix(2)))
        XCTAssertEqual(selection.selected, Set(ids.prefix(2)))
        XCTAssertEqual(selection.cursor, 1)
        selection.clamp(to: [])
        XCTAssertNil(selection.cursor)
        XCTAssertTrue(selection.selected.isEmpty)
    }

    func testTargetsPreferSelectionOverCursor() {
        var selection = TaskSelection()
        selection.click(index: 4, id: ids[4], shift: false, command: false, visible: ids)
        XCTAssertEqual(selection.targets(visible: ids), [ids[4]])
        selection.click(index: 1, id: ids[1], shift: false, command: true, visible: ids)
        XCTAssertEqual(selection.targets(visible: ids), [ids[1], ids[4]], "visible order, not click order")
        selection.clear()
        selection.cursor = 2
        XCTAssertEqual(selection.targets(visible: ids), [ids[2]], "the cursor row when nothing is selected")
        selection.cursor = nil
        XCTAssertEqual(selection.targets(visible: ids), [])
    }
}

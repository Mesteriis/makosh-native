import Foundation
import XCTest
@testable import MakoshTasks

final class TaskQuickEntryChipsTests: XCTestCase {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }()
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 7))! }  // a Saturday

    private func suggestions(_ text: String, hasList: Bool = false) -> [TaskQuickEntrySuggestion] {
        TaskQuickEntrySuggestions.make(
            for: text, lists: ["Работа", "Личное"], tags: ["релиз", "рутина"], personas: ["Боб", "Алиса"], flows: ["Релиз", "Ремонт"],
            hasList: hasList, today: today, calendar: calendar)
    }

    func testSpaceCommitsTokenIntoChip() {
        var chips = TaskQuickEntryChips()
        chips.typed("Счёт @Работа", extractURLs: true)
        XCTAssertEqual(chips.chips, [])
        XCTAssertEqual(chips.text, "Счёт @Работа")
        chips.typed("Счёт @Работа ", extractURLs: true)
        XCTAssertEqual(chips.chips, [TaskQuickEntryChips.Chip(kind: .list, raw: "@Работа")])
        XCTAssertEqual(chips.text, "Счёт ")
        chips.typed("Счёт за ноябрь ", extractURLs: true)
        XCTAssertEqual(chips.text, "Счёт за ноябрь ", "plain words stay text")
        XCTAssertEqual(chips.composed(), "@Работа Счёт за ноябрь")
        XCTAssertFalse(chips.isEmpty)
    }

    func testSecondListStaysText() {
        var chips = TaskQuickEntryChips()
        chips.typed("@Работа ", extractURLs: true)
        chips.typed("@Личное ", extractURLs: true)
        XCTAssertEqual(chips.chips.map(\.raw), ["@Работа"])
        XCTAssertEqual(chips.text, "@Личное ")
    }

    func testURLChipOnlyWhenExtractionIsOn() {
        var chips = TaskQuickEntryChips()
        chips.typed("https://example.com/a ", extractURLs: false)
        XCTAssertEqual(chips.chips, [])
        chips.typed("https://example.com/a ", extractURLs: true)
        XCTAssertEqual(chips.chips.map(\.kind), [.url])
    }

    func testBackspaceOnEmptyPopsChipBackToText() {
        var chips = TaskQuickEntryChips()
        chips.typed("#релиз ", extractURLs: true)
        XCTAssertTrue(chips.backspaceOnEmpty())
        XCTAssertEqual(chips.chips, [])
        XCTAssertEqual(chips.text, "#релиз")
        XCTAssertFalse(chips.backspaceOnEmpty())
        chips.typed("#релиз ", extractURLs: true)
        chips.typed("/Боб ", extractURLs: true)
        XCTAssertEqual(chips.chips.map(\.raw), ["#релиз", "/Боб"])
        chips.remove(at: 0)
        XCTAssertEqual(chips.chips.map(\.raw), ["/Боб"])
    }

    func testSuggestionsForEachPrefix() {
        XCTAssertEqual(suggestions("Счёт @Ра").map(\.label), ["@Работа"])
        XCTAssertEqual(suggestions("@Ра", hasList: true), [], "no second list")
        XCTAssertEqual(suggestions("#р").map(\.label), ["#релиз", "#рутина"])
        XCTAssertEqual(suggestions("/а").map(\.label), ["/Алиса"])
        XCTAssertEqual(suggestions(">>Ре").map(\.label), ["Релиз", "Ремонт"].map { ">>" + $0 })
        let priorities = suggestions("!")
        XCTAssertEqual(priorities.map(\.label), ["!1", "!2", "!3", "!4"])
        XCTAssertEqual(priorities.first?.detail, "срочно")
        XCTAssertEqual(suggestions("*").map(\.label), ["*daily", "*weekly", "*monthly", "*yearly"])
        XCTAssertEqual(suggestions("*w").map(\.label), ["*weekly"])
        XCTAssertEqual(suggestions("Слово").map(\.label), [])
    }

    func testDateSuggestionsResolveAndPreview() {
        let typed = suggestions("^завтра")
        XCTAssertEqual(typed.first?.label, "^завтра")
        XCTAssertEqual(typed.first?.detail, "→ 8 ноября, вс")
        let partial = suggestions("^за")
        XCTAssertEqual(partial.map(\.label), ["^завтра"])
        let bare = suggestions("^")
        XCTAssertEqual(bare.map(\.label), ["^сегодня", "^завтра", "^пн", "^вт", "^ср", "^чт", "^пт"])
        XCTAssertEqual(bare[2].detail, "→ 9 ноября, пн")
        let numeric = suggestions("^20")
        XCTAssertEqual(numeric.first?.label, "^20")
        XCTAssertEqual(numeric.first?.detail, "→ 20 ноября, пт")
    }

    func testAcceptSuggestionCommitsChip() {
        var chips = TaskQuickEntryChips()
        chips.typed("Счёт @Ра", extractURLs: true)
        chips.accept(suggestions(chips.text)[0])
        XCTAssertEqual(chips.chips.map(\.raw), ["@Работа"])
        XCTAssertEqual(chips.text, "Счёт ")
        chips.typed("Счёт ^за", extractURLs: true)
        chips.accept(TaskQuickEntrySuggestion(kind: .due, label: "^завтра", replace: "^завтра", detail: nil))
        XCTAssertEqual(chips.chips.map(\.raw), ["@Работа", "^завтра"])
    }
}

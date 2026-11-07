import Foundation
import XCTest
@testable import MakoshTasks

final class TaskQuickEntryTests: XCTestCase {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }()
    private var today: Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 11
        parts.day = 7
        return calendar.date(from: parts)!
    }
    private func parse(_ input: String, resolve: @escaping (String) -> UUID? = { _ in nil }) -> TaskQuickEntry {
        TaskQuickEntry.parse(input, today: today, calendar: calendar, resolveDependency: resolve)
    }

    func testTokensAreExtractedInAnyOrder() {
        let entry = parse("!1 Счёт за ноябрь @Работа #финансы ^завтра #срочно")
        XCTAssertEqual(entry.title, "Счёт за ноябрь")
        XCTAssertEqual(entry.list, "Работа")
        XCTAssertEqual(entry.tags, ["финансы", "срочно"])
        XCTAssertEqual(entry.priority, 1)
        XCTAssertEqual(entry.due, calendar.date(byAdding: .day, value: 1, to: today))
        XCTAssertEqual(entry.tokens.map(\.kind), [.priority, .text, .text, .text, .list, .tag, .due, .tag])
    }

    func testUnparsedDateStaysInTitle() {
        let entry = parse("Позвонить ^когда-нибудь")
        XCTAssertNil(entry.due)
        XCTAssertEqual(entry.title, "Позвонить ^когда-нибудь")
        XCTAssertEqual(entry.tokens.last?.kind, .due)
        XCTAssertEqual(entry.tokens.last?.resolved, false)
    }

    func testUnknownDependencyKeyStaysInTitle() {
        let entry = parse("Деплой ~ABC-123")
        XCTAssertEqual(entry.dependencyRefs, [])
        XCTAssertEqual(entry.title, "Деплой ~ABC-123")
        XCTAssertEqual(entry.tokens.last, TaskQuickEntry.Token(kind: .dependency, text: "~ABC-123", resolved: false))
    }

    func testKnownDependencyResolves() {
        let id = UUID()
        let entry = parse("Деплой ~7K3MZ") { $0 == "7K3MZ" ? id : nil }
        XCTAssertEqual(entry.dependencyRefs, ["7K3MZ"])
        XCTAssertEqual(entry.dependencies, [id])
        XCTAssertEqual(entry.title, "Деплой")
        XCTAssertEqual(entry.tokens.last?.resolved, true)
    }

    func testUrlIsPickedOnce() {
        let entry = parse("Прочитать https://example.com/a и https://example.com/b")
        XCTAssertEqual(entry.url, URL(string: "https://example.com/a"))
        XCTAssertEqual(entry.title, "Прочитать и https://example.com/b")
    }

    func testPersonaRecurrenceAndFlowTokens() {
        let entry = parse("Позвонить /Боб *weekly >>Релиз /Алиса")
        XCTAssertEqual(entry.title, "Позвонить")
        XCTAssertEqual(entry.personas, ["Боб", "Алиса"])
        XCTAssertEqual(entry.recurrence, "weekly")
        XCTAssertEqual(entry.flowID, "Релиз")
        XCTAssertEqual(entry.tokens.map(\.kind), [.text, .persona, .recurrence, .flow, .persona])
    }

    func testUnknownRecurrenceStaysInTitle() {
        let entry = parse("Платёж *каждый")
        XCTAssertNil(entry.recurrence)
        XCTAssertEqual(entry.title, "Платёж *каждый")
        XCTAssertEqual(entry.tokens.last, TaskQuickEntry.Token(kind: .recurrence, text: "*каждый", resolved: false))
        XCTAssertEqual(parse("Платёж *FREQ=MONTHLY;INTERVAL=2").recurrence, "FREQ=MONTHLY;INTERVAL=2")
    }

    func testLoneMarkersAreText() {
        let entry = parse("Знаки / * >> @ # ~")
        XCTAssertEqual(entry.title, "Знаки / * >> @ # ~")
        XCTAssertTrue(entry.tokens.allSatisfy { $0.kind == .text })
    }

    func testURLExtractionCanBeOff() {
        let entry = TaskQuickEntry.parse(
            "Прочитать https://example.com/a", today: today, calendar: calendar, resolveDependency: { _ in nil }, extractURLs: false)
        XCTAssertNil(entry.url)
        XCTAssertEqual(entry.title, "Прочитать https://example.com/a")
    }

    func testInvalidPriorityIsText() {
        let entry = parse("Задача !5")
        XCTAssertNil(entry.priority)
        XCTAssertEqual(entry.title, "Задача !5")
    }
}

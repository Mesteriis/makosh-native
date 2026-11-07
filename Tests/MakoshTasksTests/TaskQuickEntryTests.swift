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

    func testFlowRecurrencePersonaAreOrdinaryText() {
        let entry = parse("Отчёт >>релиз *weekly /Боб")
        XCTAssertEqual(entry.title, "Отчёт >>релиз *weekly /Боб")
        XCTAssertTrue(entry.tokens.allSatisfy { $0.kind == .text })
    }

    func testInvalidPriorityIsText() {
        let entry = parse("Задача !5")
        XCTAssertNil(entry.priority)
        XCTAssertEqual(entry.title, "Задача !5")
    }
}

import Foundation
import MakoshCore
import XCTest

@testable import MakoshApp

final class PersonAddressSuggestionsTests: XCTestCase {
    private func summary(_ name: String, email: String?, active: Bool = true, id: UUID = UUID()) -> PersonSummary {
        PersonSummary(
            id: id, kind: .person, displayName: name, organization: "", jobTitle: "", firstEmail: email, firstPhone: nil,
            addressBook: false, isActive: active, revision: 1)
    }

    func testSuggestsByNameAndAddressFromTwoCharacters() {
        let ivan = UUID()
        let persons = [
            summary("Иван Сидоров", email: "ivan@sidorov.ru", id: ivan), summary("Пётр Петров", email: "petr@example.com"),
            summary("Без адреса", email: nil),
        ]
        let emails = [ivan: ["ivan@sidorov.ru", "sidorov@work.ru"]]
        XCTAssertTrue(
            PersonAddressSuggestions.suggestions(typed: "И", persons: persons, emails: emails).isEmpty, "one character is too early")
        let byName = PersonAddressSuggestions.suggestions(typed: "ив", persons: persons, emails: emails)
        XCTAssertEqual(byName.map(\.address), ["ivan@sidorov.ru", "sidorov@work.ru"], "a name match offers every address of the person")
        XCTAssertEqual(byName.map(\.name), ["Иван Сидоров", "Иван Сидоров"])
        let byAddress = PersonAddressSuggestions.suggestions(typed: "EXAMPLE", persons: persons, emails: emails)
        XCTAssertEqual(byAddress.map(\.address), ["petr@example.com"], "addresses match case-insensitively and fall back to firstEmail")
        XCTAssertEqual(
            PersonAddressSuggestions.suggestions(typed: "work", persons: persons, emails: emails).map(\.address), ["sidorov@work.ru"])
    }

    func testInactivePersonsAreNotSuggested() {
        let persons = [summary("Иван Живой", email: "alive@x.ru"), summary("Иван Удалённый", email: "gone@x.ru", active: false)]
        XCTAssertEqual(PersonAddressSuggestions.suggestions(typed: "иван", persons: persons, emails: [:]).map(\.address), ["alive@x.ru"])
    }

    func testLimitSix() {
        let persons = (1...10).map { summary("Коллега \($0)", email: "c\($0)@x.ru") }
        XCTAssertEqual(PersonAddressSuggestions.suggestions(typed: "колл", persons: persons, emails: [:]).count, 6)
    }

    func testInsertReplacesTheTypedFragment() {
        XCTAssertEqual(PersonAddressSuggestions.fragment(of: "a@x.ru, Ив"), "Ив")
        XCTAssertEqual(PersonAddressSuggestions.fragment(of: ""), "")
        XCTAssertEqual(
            PersonAddressSuggestions.insert(address: "ivan@sidorov.ru", name: "Иван Сидоров", into: "a@x.ru, Ив"),
            "a@x.ru, Иван Сидоров <ivan@sidorov.ru>, ")
        XCTAssertEqual(PersonAddressSuggestions.insert(address: "p@x.ru", name: "", into: "p@"), "p@x.ru, ", "no name — the bare address")
        XCTAssertEqual(PersonAddressSuggestions.insert(address: "p@x.ru", name: "p@x.ru", into: "p@"), "p@x.ru, ")
    }
}

import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class PersonCardTests: XCTestCase {
    func testBuilderPrefersConfirmedMembership() {
        var person = Person(displayName: "Иванов Пётр", jobTitle: "Инженер", phones: ["+7 1"], emails: ["a@x"])
        person.givenName = "Пётр"
        person.familyName = "Иванов"
        let suggested = Person(id: UUID(), displayName: "sidorov.ru")
        let confirmed = Person(id: UUID(), displayName: "ИП Сидоров")
        let memberships = [
            PersonMembership(
                organizationID: suggested.id, personID: person.id, role: "", origin: .emailDomain("sidorov.ru"), state: .suggested),
            PersonMembership(organizationID: confirmed.id, personID: person.id, role: "Менеджер", origin: .manual, state: .confirmed),
        ]
        let card = PersonCardBuilder.card(
            for: person, memberships: memberships, organizations: [suggested.id: suggested, confirmed.id: confirmed])
        XCTAssertEqual(card.organization, "ИП Сидоров")
        XCTAssertEqual(card.jobTitle, "Менеджер")
        XCTAssertEqual(card.givenName, "Пётр")
        XCTAssertEqual(card.familyName, "Иванов")
        XCTAssertEqual(card.makoshID, person.id)
        XCTAssertEqual(card.kind, .person)
    }

    func testBuilderUsesOwnOrganizationFieldAndSplitsDisplayName() {
        let person = Person(displayName: "Анна Каренина", organization: "ООО Ромашка", jobTitle: "Директор")
        let card = PersonCardBuilder.card(for: person, memberships: [], organizations: [:])
        XCTAssertEqual(card.organization, "ООО Ромашка")
        XCTAssertEqual(card.jobTitle, "Директор")
        XCTAssertEqual(card.givenName, "Анна")
        XCTAssertEqual(card.familyName, "Каренина")
    }

    func testBuilderForOrganizationHasNoPersonalName() {
        var organization = Person(displayName: "ИП Сидоров", emails: ["info@sidorov.ru"])
        organization.kind = .organization
        let card = PersonCardBuilder.card(for: organization, memberships: [], organizations: [:])
        XCTAssertEqual(card.kind, .organization)
        XCTAssertEqual(card.displayName, "ИП Сидоров")
        XCTAssertEqual(card.givenName, "")
        XCTAssertEqual(card.familyName, "")
    }
}

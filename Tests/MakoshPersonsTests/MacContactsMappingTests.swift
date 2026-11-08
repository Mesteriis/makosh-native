import Contacts
import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class MacContactsMappingTests: XCTestCase {
    private let id = UUID()

    func testMacMappingRoundTripsPerson() throws {
        let card = PersonCard(
            makoshID: id, kind: .person, displayName: "Иванов Пётр", givenName: "Пётр", familyName: "Иванов", middleName: "Сергеевич",
            phones: ["+7 916 000-00-00"], emails: ["ivanov@sidorov.ru"], organization: "ИП Сидоров", jobTitle: "Менеджер")
        let contact = CNMutableContact()
        MacContactsMapping.apply(card, to: contact)
        XCTAssertEqual(contact.contactType, .person)
        XCTAssertEqual(contact.givenName, "Пётр")
        XCTAssertEqual(contact.familyName, "Иванов")
        XCTAssertEqual(contact.middleName, "Сергеевич")
        XCTAssertEqual(contact.organizationName, "ИП Сидоров")
        XCTAssertEqual(contact.jobTitle, "Менеджер")
        XCTAssertEqual(contact.phoneNumbers.map { $0.value.stringValue }, ["+7 916 000-00-00"])
        XCTAssertEqual(contact.emailAddresses.map { $0.value as String }, ["ivanov@sidorov.ru"])
        let (imported, kind) = MacContactsMapping.card(contact)
        XCTAssertEqual(kind, .person)
        XCTAssertEqual(imported.displayName, "Пётр Сергеевич Иванов")
        XCTAssertEqual(imported.givenName, "Пётр")
        XCTAssertEqual(imported.familyName, "Иванов")
        XCTAssertEqual(imported.phones, ["+7 916 000-00-00"])
        XCTAssertEqual(imported.emails, ["ivanov@sidorov.ru"])
        XCTAssertEqual(imported.organization, "ИП Сидоров")
        XCTAssertEqual(imported.jobTitle, "Менеджер")
        XCTAssertEqual(imported.externalID, contact.identifier)
    }

    func testMacMappingRoundTripsOrganization() {
        let card = PersonCard(
            makoshID: id, kind: .organization, displayName: "ООО Ромашка", givenName: "", familyName: "", middleName: "", phones: [],
            emails: ["info@romashka.ru"], organization: "", jobTitle: "")
        let contact = CNMutableContact()
        MacContactsMapping.apply(card, to: contact)
        XCTAssertEqual(contact.contactType, .organization)
        XCTAssertEqual(contact.organizationName, "ООО Ромашка")
        XCTAssertEqual(contact.givenName, "")
        let (imported, kind) = MacContactsMapping.card(contact)
        XCTAssertEqual(kind, .organization)
        XCTAssertEqual(imported.displayName, "ООО Ромашка")
        XCTAssertEqual(imported.kind, .organization)
    }

    func testApplyReplacesListsInsteadOfAppending() {
        let contact = CNMutableContact()
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+7 000"))]
        let card = PersonCard(
            makoshID: id, kind: .person, displayName: "А", givenName: "А", familyName: "", middleName: "", phones: ["+7 111"], emails: [],
            organization: "", jobTitle: "")
        MacContactsMapping.apply(card, to: contact)
        XCTAssertEqual(contact.phoneNumbers.map { $0.value.stringValue }, ["+7 111"])
    }
}

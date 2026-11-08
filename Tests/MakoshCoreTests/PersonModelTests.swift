import Foundation
import XCTest

@testable import MakoshCore

enum PersonFixture {
    /// A record as version 2 of the store wrote it: no kind, former, manualValues or addressBook.
    static func contactV2JSON(
        id: UUID = UUID(), manualFields: [String] = ["displayName"], phones: [String] = ["+7 916 000-00-00"]
    ) -> Data {
        let manual = manualFields.map { "\"\($0)\"" }.joined(separator: ",")
        let phoneList = phones.map { "\"\($0)\"" }.joined(separator: ",")
        return Data(
            """
            {"id":"\(id.uuidString)","displayName":"Иванов Пётр","organization":"ИП Сидоров","jobTitle":"Менеджер",
             "phones":[\(phoneList)],"emails":["ivanov@sidorov.ru"],"tags":[],
             "identities":[{"service":"mail","accountID":"a","externalID":"ivanov@sidorov.ru"}],
             "observations":[{"id":"\(UUID().uuidString)","field":"displayName","value":"Иванов Пётр",
               "source":{"identity":{"service":"mail","accountID":"a","externalID":"ivanov@sidorov.ru"},"fetchedAt":100}}],
             "notes":[],"events":[{"id":"\(UUID().uuidString)","date":50,"kind":"import","detail":"x"}],"manualFields":[\(manual)],"revision":3}
            """.utf8)
    }
}

final class PersonModelTests: XCTestCase {
    func testOldPayloadDecodesWithDefaults() throws {
        let person = try JSONDecoder().decode(Person.self, from: PersonFixture.contactV2JSON())
        XCTAssertEqual(person.kind, .person)
        XCTAssertFalse(person.addressBook)
        XCTAssertNil(person.addressBookOrigin)
        XCTAssertTrue(person.former.isEmpty)
        XCTAssertTrue(person.manualValues.isEmpty)
        XCTAssertEqual(person.observations.first?.status, .observed)
        XCTAssertTrue(person.isActive)
        XCTAssertEqual(person.givenName, "")
        XCTAssertEqual(person.usernames, [])
        XCTAssertEqual(
            person.createdAt, Date(timeIntervalSinceReferenceDate: 50), "The earliest event stands in for a missing creation time")
    }

    func testNamePartsFallBackToDisplayName() {
        XCTAssertEqual(Person(displayName: "Иванов Пётр").nameParts.given, "Иванов")
        XCTAssertEqual(Person(displayName: "Иванов Пётр").nameParts.family, "Пётр")
        XCTAssertEqual(Person(displayName: "Анна").nameParts.given, "Анна")
        XCTAssertEqual(Person(displayName: "Анна").nameParts.family, "")
        var person = Person(displayName: "x")
        person.givenName = "Пётр"
        person.familyName = "Иванов"
        XCTAssertEqual(person.nameParts.given, "Пётр")
        XCTAssertEqual(person.nameParts.family, "Иванов")
    }

    func testSummaryCarriesListFirsts() {
        var person = Person(displayName: "A", organization: "Org", jobTitle: "Job", phones: ["+7 1", "+7 2"], emails: ["a@x", "b@x"])
        person.addressBook = true
        person.kind = .organization
        let summary = person.summary
        XCTAssertEqual(summary.id, person.id)
        XCTAssertEqual(summary.firstEmail, "a@x")
        XCTAssertEqual(summary.firstPhone, "+7 1")
        XCTAssertEqual(summary.kind, .organization)
        XCTAssertTrue(summary.addressBook)
        XCTAssertTrue(summary.isActive)
        XCTAssertEqual(summary.organization, "Org")
        XCTAssertEqual(summary.revision, person.revision)
    }

    func testListFieldAccessorsRoundTrip() {
        var person = Person(displayName: "A")
        for field in PersonListField.allCases {
            person.setValues(["v-\(field.rawValue)"], for: field)
            XCTAssertEqual(person.values(field), ["v-\(field.rawValue)"])
        }
        XCTAssertEqual(person.phones, ["v-phones"])
        XCTAssertEqual(person.usernames, ["v-usernames"])
    }

    func testPersonRoundTripsThroughJSON() throws {
        var person = Person(displayName: "Иванов Пётр", phones: ["+7 1"])
        person.kind = .person
        person.givenName = "Пётр"
        person.familyName = "Иванов"
        person.middleName = "Сергеевич"
        person.usernames = ["ivanov"]
        person.manualValues = [ManualValue(field: "phones", value: "+7 1")]
        person.former = [
            FormerValue(field: "phones", value: "+7 0", since: Date(timeIntervalSince1970: 10), reason: .removedByUser),
            FormerValue(
                field: "emails", value: "old@x", since: Date(timeIntervalSince1970: 20),
                reason: .removedInBook(ImportSource(service: "google-contacts", accountID: "s"))),
        ]
        person.addressBook = true
        person.addressBookOrigin = .sourceAccount(ImportSource(service: "carddav", accountID: "b"))
        person.deletedAt = Date(timeIntervalSince1970: 30)
        person.hiddenAsSpam = true
        person.observations = [
            Observation(
                field: "emails", value: "p@x", source: SourceStamp(identity: .init(service: "ai", accountID: "local", externalID: "1")),
                status: .proposed)
        ]
        let decoded = try JSONDecoder().decode(Person.self, from: JSONEncoder().encode(person))
        XCTAssertEqual(decoded, person)
        XCTAssertFalse(decoded.isActive)
    }

    func testImportedPersonDecodesWithoutStructuredName() throws {
        let data = Data(#"{"externalID":"1","displayName":"A"}"#.utf8)
        let imported = try JSONDecoder().decode(ImportedPerson.self, from: data)
        XCTAssertNil(imported.givenName)
        XCTAssertEqual(imported.usernames, [])
    }
}

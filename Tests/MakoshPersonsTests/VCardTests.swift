import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class VCardTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private func card() -> PersonCard {
        PersonCard(
            makoshID: id, kind: .person, displayName: "Иванов Пётр Сергеевич", givenName: "Пётр", familyName: "Иванов",
            middleName: "Сергеевич", phones: ["+7 916 000-00-00", "+7 495 111-11-11"], emails: ["ivanov@sidorov.ru"],
            organization: "ИП Сидоров", jobTitle: "Менеджер")
    }

    func testSerializeRoundTrips() throws {
        let text = VCard.serialize(card())
        XCTAssertTrue(text.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0\r\n"))
        XCTAssertTrue(text.contains("X-MAKOSH-PERSON:11111111-2222-4333-8444-555555555555"))
        XCTAssertTrue(text.contains("N:Иванов;Пётр;Сергеевич;;"))
        let parsed = try VCard.parse(text)
        XCTAssertEqual(parsed.imported.displayName, "Иванов Пётр Сергеевич")
        XCTAssertEqual(parsed.imported.givenName, "Пётр")
        XCTAssertEqual(parsed.imported.familyName, "Иванов")
        XCTAssertEqual(parsed.imported.middleName, "Сергеевич")
        XCTAssertEqual(parsed.imported.phones, ["+7 916 000-00-00", "+7 495 111-11-11"])
        XCTAssertEqual(parsed.imported.emails, ["ivanov@sidorov.ru"])
        XCTAssertEqual(parsed.imported.organization, "ИП Сидоров")
        XCTAssertEqual(parsed.imported.jobTitle, "Менеджер")
        XCTAssertEqual(parsed.makoshID, id)
        XCTAssertEqual(parsed.kind, .person)
        XCTAssertEqual(parsed.uid, id.uuidString)
    }

    func testEscapesAndFoldsLongLines() throws {
        var card = card()
        card.displayName =
            "Имя, с запятой; и точкой с запятой\nи переносом " + Array(repeating: "очень длинное", count: 8).joined(separator: " ")
        let text = VCard.serialize(card)
        XCTAssertTrue(VCard.unfold(text).joined(separator: "\n").contains("Имя\\, с запятой\\; и точкой с запятой\\nи переносом"))
        for line in text.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 76, line) }
        XCTAssertTrue(text.contains("\r\n "), "a long line is folded")
        let parsed = try VCard.parse(text)
        XCTAssertEqual(parsed.imported.displayName, card.displayName)
    }

    func testOrganizationCardIsMarked() throws {
        let organization = PersonCard(
            makoshID: id, kind: .organization, displayName: "ИП Сидоров", givenName: "", familyName: "", middleName: "", phones: [],
            emails: ["info@sidorov.ru"], organization: "", jobTitle: "")
        let text = VCard.serialize(organization)
        XCTAssertTrue(text.contains("X-ABShowAs:COMPANY"))
        XCTAssertTrue(text.contains("KIND:org"))
        XCTAssertTrue(text.contains("ORG:ИП Сидоров"))
        XCTAssertFalse(text.contains("\r\nN:"), "an organization has no structured personal name")
        let parsed = try VCard.parse(text)
        XCTAssertEqual(parsed.kind, .organization)
        XCTAssertEqual(parsed.imported.displayName, "ИП Сидоров")
    }

    func testParseIgnoresUnknownPropertiesAndPhoto() throws {
        let text = """
            BEGIN:VCARD\r
            VERSION:3.0\r
            UID:abc\r
            FN:Анна\r
            N:;Анна;;;\r
            PHOTO;ENCODING=b;TYPE=JPEG:/9j/4AAQSkZJRgABAQAAAQABAAD\r
             AAAAAAAAAAAAAAAAAAA\r
            X-FOO:bar\r
            TEL;TYPE=CELL:+7 916 000-00-00\r
            EMAIL;TYPE=INTERNET;TYPE=HOME:Anna@Example.ru\r
            NOTE:Коллега\r
            END:VCARD\r

            """
        let parsed = try VCard.parse(text)
        XCTAssertEqual(parsed.imported.displayName, "Анна")
        XCTAssertEqual(parsed.imported.givenName, "Анна")
        XCTAssertEqual(parsed.imported.phones, ["+7 916 000-00-00"])
        XCTAssertEqual(parsed.imported.emails, ["Anna@Example.ru"])
        XCTAssertEqual(parsed.imported.notes, ["Коллега"])
        XCTAssertNil(parsed.makoshID)
        XCTAssertEqual(parsed.uid, "abc")
        XCTAssertEqual(parsed.kind, .person)
    }

    func testParseRejectsNonVCard() {
        XCTAssertThrowsError(try VCard.parse("hello"))
        XCTAssertThrowsError(try VCard.parse("BEGIN:VCARD\r\nVERSION:3.0\r\nEND:VCARD\r\n"), "a card without FN has no name")
    }

    func testFingerprintIgnoresOrderAndWhitespace() {
        var a = card()
        var b = card()
        a.phones = ["+7 495 111-11-11", "+7 916 000-00-00"]
        b.displayName = " " + b.displayName + " "
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        b.emails = ["other@x"]
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        XCTAssertEqual(a.fingerprint.count, 64)
    }
}

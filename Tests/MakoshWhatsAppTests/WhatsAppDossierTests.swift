import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppDossierTests: XCTestCase {
  func testLIDIsNotInventedAsPhoneAndGroupsAreNotPeople() throws {
    let lid = WhatsAppChat(id: "12345@lid", name: "A source person")
    let person = try XCTUnwrap(lid.dossierContact)
    XCTAssertEqual(person.externalID, "12345@lid")
    XCTAssertTrue(person.phones.isEmpty)
    XCTAssertEqual(
      WhatsAppChat(id: "34612345678@s.whatsapp.net", name: "Phone person").dossierContact?.phones,
      ["+34612345678"])
    XCTAssertNil(WhatsAppChat(id: "group@g.us", name: "Group", group: true).dossierContact)
  }
}

import XCTest

@testable import MakoshWhatsApp

final class WhatsAppContactPresentationTests: XCTestCase {
  func testVCardFoldedEscapedAndMultiplePhonesRetainsRawSource() throws {
    let raw =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Анна\\, Иванова\r\nN:Иванова;Анна;;;\r\nTEL;TYPE=CELL,VOICE:+79990000001\r\nTEL;TYPE=WORK:tel:+34600000002\r\nEMAIL;TYPE=WORK:anna@example.test\r\nORG:Макош\\; Исследования;\r\n Отдел\r\nPHOTO;VALUE=URI:https://example.test/private.png\r\nEND:VCARD\r\n"
    var message = waRichMessage(kind: "contact", text: "")
    message.details = .init()
    message.details?.contactName = "Fallback"
    message.details?.contactVcard = raw
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let before = try encoder.encode(message)
    let value = try XCTUnwrap(WhatsAppMessagePresentation.make(message).contact)
    XCTAssertEqual(value.name, "Анна, Иванова")
    XCTAssertEqual(
      value.fields.filter { $0.kind == .phone }.map(\.value), ["+79990000001", "+34600000002"])
    XCTAssertEqual(value.fields.filter { $0.kind == .email }.map(\.value), ["anna@example.test"])
    XCTAssertEqual(
      value.fields.filter { $0.kind == .organization }.map(\.value), ["Макош; Исследования · Отдел"]
    )
    XCTAssertFalse(value.isMalformed)
    XCTAssertEqual(try encoder.encode(message), before)
    XCTAssertEqual(message.details?.contactVcard, raw)
    XCTAssertFalse(value.fields.contains { $0.value.contains("private.png") })
  }

  func testStructuredV4NameAndQuotedType() {
    let raw =
      "BEGIN:VCARD\nVERSION:4.0\nN:Иванова;Анна;Петровна;;\nTEL;TYPE=\"cell,voice\";VALUE=uri:tel:+79990000003\nEND:VCARD"
    let value = WhatsAppContactParser.parse(raw, fallbackName: "Контакт")
    XCTAssertEqual(value.name, "Анна Петровна Иванова")
    XCTAssertEqual(value.fields.first?.kind, .phone)
    XCTAssertEqual(value.fields.first?.value, "+79990000003")
    XCTAssertFalse(value.isMalformed)
  }

  func testMalformedAndOversizedCardHasSafeFallback() {
    for raw in [
      "not a vCard", "BEGIN:VCARD\nFN:Broken\n", String(repeating: "x", count: 256 * 1024 + 1),
    ] {
      let value = WhatsAppContactParser.parse(raw, fallbackName: "Сохранённый контакт")
      XCTAssertEqual(value.name, "Сохранённый контакт")
      XCTAssertTrue(value.isMalformed)
      XCTAssertTrue(value.fields.isEmpty)
    }
    let manyLines =
      "BEGIN:VCARD\nVERSION:3.0\n" + String(repeating: "NOTE:x\n", count: 2048) + "END:VCARD"
    XCTAssertTrue(WhatsAppContactParser.parse(manyLines, fallbackName: "Имя").isMalformed)
    let manyFields =
      "BEGIN:VCARD\nVERSION:3.0\nFN:Иван\n" + (0..<130).map { "TEL:+7000\($0)\n" }.joined()
      + "END:VCARD"
    let bounded = WhatsAppContactParser.parse(manyFields, fallbackName: "Контакт")
    XCTAssertEqual(bounded.fields.count, 128)
    XCTAssertTrue(bounded.isMalformed)
  }
}

func waRichMessage(kind: String, text: String) -> WhatsAppMessage {
  .init(
    chat: "peer@lid", id: "rich", stanza: "rich", sender: "peer@lid", timestamp: 1,
    outgoing: false, text: text, kind: kind, edited: false, deleted: false)
}

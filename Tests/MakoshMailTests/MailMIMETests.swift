import XCTest
@testable import MakoshMail

final class MailMIMETests: XCTestCase {
    func testLongOutgoingPartsUseOnlyCRLFAndRoundtrip() {
        let body = String(repeating: "Длинное письмо ", count: 100)
        let bytes = Data(repeating: 255, count: 1000)
        let raw = MIME.buildMessage(from: "qa@example.invalid", fromName: nil, to: "peer@example.invalid", subject: "Long", body: body, attachments: [.init(filename: "a.bin", mimeType: "application/octet-stream", data: bytes)], bodyHTML: "<p>" + body + "</p>")
        let withoutCRLF = raw.replacingOccurrences(of: "\r\n", with: "")
        XCTAssertFalse(withoutCRLF.contains("\r")); XCTAssertFalse(withoutCRLF.contains("\n"))
        let parsed = MIME.parse(Data(raw.utf8))
        XCTAssertEqual(parsed.text, body); XCTAssertEqual(parsed.attachments.first?.data, bytes)
    }
    func testBinaryEightBitAttachmentRemainsExact() {
        var raw = Data("Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"binary.bin\"\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
        let payload = Data([0, 255, 128, 13, 10, 42])
        raw.append(payload); raw.append(Data("\r\n--x--\r\n".utf8))
        XCTAssertEqual(MIME.parse(raw).attachments.first?.data, payload)
    }
    func testClosingMultipartDelimiterDoesNotBecomeBody() {
        let raw = Data("Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=a\r\n\r\na\r\n--x--\r\nepilogue".utf8)
        XCTAssertEqual(MIME.parse(raw).text, "")
    }
    func testQuotedPrintableSoftLineBreak() {
        XCTAssertEqual(MIME.parse(Data("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nhello=\r\nworld".utf8)).text, "helloworld")
    }
    func testOutgoingHeaderCannotInjectBcc() {
        let raw = MIME.buildMessage(from: "qa@example.invalid", fromName: nil, to: "peer@example.invalid", subject: "subject\r\nBcc: victim@example.invalid", body: "test")
        XCTAssertFalse(raw.contains("\r\nBcc:"))
    }
    func testMultipartRoundtrip() {
        let data = Data([0,1,2,255])
        let raw = MIME.buildMessage(from: "qa@example.invalid", fromName: "Тест", to: "peer@example.invalid", subject: "Письмо", body: "Привет", attachments: [.init(filename: "file.bin", mimeType: "application/octet-stream", data: data)], bodyHTML: "<p>Привет</p>")
        let parsed = MIME.parse(Data(raw.utf8))
        XCTAssertEqual(parsed.text,"Привет"); XCTAssertEqual(parsed.html,"<p>Привет</p>")
        XCTAssertEqual(parsed.attachments.first?.data,data)
    }
}

extension MailMIMETests {
    func testUnnamedInlineImageIsFileRatherThanText() {
        var raw=Data("Content-Type: multipart/related; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\nhello\r\n--x\r\nContent-Type: image/png\r\nContent-ID: <image1>\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
        let bytes=Data([137,80,78,71,0,255]);raw.append(bytes);raw.append(Data("\r\n--x--\r\n".utf8))
        let result=MIME.parse(raw);XCTAssertEqual(result.text,"hello");XCTAssertEqual(result.attachments.first?.data,bytes)
    }
    func testExtendedUTF8FilenameAndQuotedSemicolon() {
        let raw=Data("Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename*=utf-8''%D0%A4%D0%B0%D0%B9%D0%BB.bin\r\nContent-Transfer-Encoding: base64\r\n\r\nAQID".utf8)
        XCTAssertEqual(MIME.parse(raw).attachments.first?.filename,"Файл.bin")
        let quoted=Data("Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"one;two.bin\"\r\n\r\ntest".utf8)
        XCTAssertEqual(MIME.parse(quoted).attachments.first?.filename,"one;two.bin")
    }
}

import Foundation
import XCTest
@testable import MakoshJira

final class JiraADFTests: XCTestCase {
    private func adf(_ json: String) -> Data { Data(json.utf8) }
    private let paragraphs = """
        {"type":"doc","version":1,"content":[
          {"type":"paragraph","content":[{"type":"text","text":"Первая"},{"type":"hardBreak"},{"type":"text","text":"строка","marks":[{"type":"strong"}]}]},
          {"type":"paragraph","content":[{"type":"text","text":"Вторая"}]}]}
        """
    private let mention = """
        {"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Привет, "},{"type":"mention","attrs":{"id":"me-1","text":"@Я"}},{"type":"text","text":"!"}]}]}
        """
    private let table = """
        {"type":"doc","version":1,"content":[{"type":"table","content":[{"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]}]},{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"b"}]}]}]}]}]}
        """
    private let media = """
        {"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"см."}]},{"type":"mediaSingle","content":[{"type":"media","attrs":{"id":"x","type":"file"}}]}]}
        """
    private let list = """
        {"type":"doc","version":1,"content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"один"}]}]},{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"два"}]}]}]}]}
        """

    func testParagraphsAndHardBreaksProject() {
        XCTAssertEqual(JiraADF.text(from: adf(paragraphs)), "Первая\nстрока\n\nВторая")
    }

    func testMentionProjectsAsDisplayName() {
        XCTAssertEqual(JiraADF.text(from: adf(mention)), "Привет, @Я!")
    }

    func testTableIsNotSimple() {
        XCTAssertFalse(JiraADF.isSimple(adf(table)))
        XCTAssertEqual(JiraADF.text(from: adf(table)), "a | b")
    }

    func testMediaIsNotSimple() {
        XCTAssertFalse(JiraADF.isSimple(adf(media)))
        XCTAssertTrue(JiraADF.text(from: adf(media)).contains("[вложение]"))
    }

    func testOnlyWhatTheBuilderReproducesIsSimple() {
        // Lists, marks and mentions survive projection but not the rebuild from text,
        // so editing them would flatten the original: they are read-only.
        XCTAssertFalse(JiraADF.isSimple(adf(list)))
        XCTAssertFalse(JiraADF.isSimple(adf(paragraphs)), "a strong mark would be lost")
        XCTAssertFalse(JiraADF.isSimple(adf(mention)))
        let plain = """
            {"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Первая"},{"type":"hardBreak"},{"type":"text","text":"строка"}]},{"type":"paragraph","content":[{"type":"text","text":"Вторая"}]}]}
            """
        XCTAssertTrue(JiraADF.isSimple(adf(plain)))
        XCTAssertEqual(JiraADF.text(from: adf(list)), "• один\n\n• два")
    }

    func testSimpleDocumentRoundTripsThroughTheBuilder() {
        let plain = """
            {"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Первая"},{"type":"hardBreak"},{"type":"text","text":"строка"}]},{"type":"paragraph","content":[{"type":"text","text":"Вторая"}]}]}
            """
        let rebuilt = JiraADF.document(fromText: JiraADF.text(from: adf(plain)))
        XCTAssertEqual(JiraADF.text(from: rebuilt), JiraADF.text(from: adf(plain)))
        XCTAssertTrue(JiraADF.isSimple(rebuilt))
    }

    func testDocumentFromTextRoundTrips() throws {
        let text = "Первый абзац\nвторая строка\n\nВторой абзац с @Я"
        let data = JiraADF.document(fromText: text, mentions: ["Я": "me-1"])
        XCTAssertEqual(JiraADF.text(from: data), text)
        XCTAssertFalse(JiraADF.isSimple(data), "a mention is not rebuilt from text without its map")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "doc")
        XCTAssertEqual(object["version"] as? Int, 1)
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        let second = try XCTUnwrap(content[1]["content"] as? [[String: Any]])
        XCTAssertEqual(second.last?["type"] as? String, "mention")
        XCTAssertEqual((second.last?["attrs"] as? [String: Any])?["id"] as? String, "me-1")
    }

    func testEmptyTextIsAnEmptyDocument() {
        XCTAssertEqual(JiraADF.text(from: JiraADF.document(fromText: "   ")), "")
    }
}

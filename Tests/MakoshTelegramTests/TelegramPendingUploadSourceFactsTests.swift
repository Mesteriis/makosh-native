import XCTest
import Foundation
@testable import MakoshTelegram

func pendingUploadSourceFactsJSON() throws -> [String: Any] {
    var json = try pendingUploadBatchJSON(), items = json["items"] as! [[String: Any]]
    for index in items.indices {
        let record = items[index]["file"] as! [String: Any], attachment = record["attachment"] as! [String: Any]
        items[index]["sourceFacts"] = ["itemID": items[index]["id"]!, "role": "prepared",
            "name": attachment["name"]!, "byteCount": record["plaintextByteCount"]!,
            "plaintextSHA256": record["plaintextSHA256"]!, "selectionMIME": "text/plain",
            "image": ["kind": "notImage"], "grouping": "ordinary"]
    }
    json["schemaVersion"] = 14; json["presentation"] = "file"; json["items"] = items
    return json
}

final class TelegramPendingUploadSourceFactsTests: XCTestCase {
    // Catches broadening old Media pointers or requiring a visual payload after the new source policy is explicit.
    func testAllDocumentMediaIsVersionedAndRoundTripsWithoutChangingPayloadKinds() throws {
        var json = try pendingUploadSourceFactsJSON(), items = json["items"] as! [[String: Any]]
        for index in items.indices {
            var facts = items[index]["sourceFacts"] as! [String: Any]
            facts["selectionMIME"] = "image/png"
            facts["image"] = ["kind": "decoded", "width": 64, "height": 64]
            items[index]["sourceFacts"] = facts
        }
        json["items"] = items; json["presentation"] = "media"
        for version in [14, 15] {
            json["schemaVersion"] = version
            XCTAssertFalse(try decode(json).isValid, "Old all-document Media must remain invalid")
        }
        json["schemaVersion"] = 17
        let draft: TelegramPendingUploadDraft
        do { draft = try decode(json) }
        catch { return XCTFail("The versioned source-only Media policy must decode: \(error)") }
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.items.map { $0.file.attachment.kind }, ["file", "file"])
        let saved = try JSONEncoder().encode(draft)
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: saved), draft)
        var unknown = json; unknown["futureMediaPolicy"] = true; try assertRefused(unknown)
        var incomplete = items; incomplete[0].removeValue(forKey: "sourceFacts")
        var invalid = json; invalid["items"] = incomplete; try assertRefused(invalid)
        var noMedia = items
        for index in noMedia.indices {
            var facts = noMedia[index]["sourceFacts"] as! [String: Any]
            facts["selectionMIME"] = "text/plain"; facts["image"] = ["kind": "notImage"]
            noMedia[index]["sourceFacts"] = facts
        }
        invalid["items"] = noMedia; try assertRefused(invalid)
    }

    private func decode(_ json: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func assertRefused(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        do {
            let draft = try decode(json)
            XCTAssertFalse(draft.isValid, "Invalid source facts must not become sendable", file: file, line: line)
        }
        catch is DecodingError { }
    }

    // Catches dropping source facts on restart or silently treating schema14 as legacy resources.
    func testCompleteSourceFactsSurviveTheStrictPreparationCodec() throws {
        let json = try pendingUploadSourceFactsJSON(), draft: TelegramPendingUploadDraft
        do { draft = try decode(json) }
        catch { return XCTFail("Complete schema14 source facts must decode: \(error)") }
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.schemaVersion, 14)
        XCTAssertEqual(draft.items.count, 2); XCTAssertTrue(draft.isGrouped)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        let items = try XCTUnwrap(encoded["items"] as? [[String: Any]])
        for (expected, actual) in zip(json["items"] as! [[String: Any]], items) {
            XCTAssertEqual(expected["sourceFacts"] as? NSDictionary, actual["sourceFacts"] as? NSDictionary)
        }
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONEncoder().encode(draft)), draft)
    }

    // Catches using another item's authenticated raw bytes to justify this item's source rules.
    func testFactsMustBindTheExactItemRoleNameSizeAndPlaintextHash() throws {
        let json = try pendingUploadSourceFactsJSON()
        let mutations: [(String, Any)] = [
            ("itemID", "00000000-0000-0000-0000-000000000012"), ("role", "original"),
            ("name", "second.txt"), ("byteCount", 999), ("plaintextSHA256", String(repeating: "b", count: 64)),
            ("grouping", "music"), ("grouping", "voice"), ("grouping", "animated")
        ]
        for (key, value) in mutations {
            var invalid = json, items = invalid["items"] as! [[String: Any]], facts = items[0]["sourceFacts"] as! [String: Any]
            facts[key] = value; items[0]["sourceFacts"] = facts; invalid["items"] = items
            try assertRefused(invalid)
        }
    }

    // Catches partial upgrade, discriminator nulls, future fields and downgraded fact-bearing pointers.
    func testPartialUnknownNullAndOlderSchemaFactsAreRefused() throws {
        let json = try pendingUploadSourceFactsJSON()
        for action in 0..<6 {
            var invalid = json, items = invalid["items"] as! [[String: Any]]
            switch action {
            case 0: items[1].removeValue(forKey: "sourceFacts")
            case 1: items[0]["sourceFacts"] = NSNull()
            case 2: var facts = items[0]["sourceFacts"] as! [String: Any]; facts["future"] = true; items[0]["sourceFacts"] = facts
            case 3: var facts = items[0]["sourceFacts"] as! [String: Any]; facts["image"] = ["kind": "notImage", "width": 80]; items[0]["sourceFacts"] = facts
            case 4: invalid["schemaVersion"] = 8
            default: invalid["futureSourcePolicy"] = true
            }
            invalid["items"] = items; try assertRefused(invalid)
        }
        let legacy = try pendingUploadBatchFixture()
        XCTAssertTrue(legacy.isValid); XCTAssertEqual(legacy.schemaVersion, 6)
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertTrue((roundTrip["items"] as! [[String: Any]]).allSatisfy { $0["sourceFacts"] == nil })
    }
}

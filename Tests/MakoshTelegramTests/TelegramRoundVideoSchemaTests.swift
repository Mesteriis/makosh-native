import Foundation
import XCTest
@testable import MakoshTelegram

final class TelegramRoundVideoSchemaTests: XCTestCase {
    // A round recording must retain explicit intent and its own recovery format;
    // ordinary picked video must never acquire it from a filename or MIME type.
    func testExplicitRoundVideoRoundtripsSchemaThirteenForBothLifetimeModes() throws {
        for once in [false, true] {
            let literal = try decode(fixture(once: once))
            XCTAssertTrue(literal.isValid)
            XCTAssertEqual(literal.schemaVersion, 13)
            let draft = try TelegramPendingUploadDraft(id: literal.id, accountID: 1, chatID: 42,
                title: "Synthetic round", captionInput: .empty, originalDraft: nil, replyTarget: nil,
                items: literal.items, isGrouped: false, presentation: .media)
            XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.schemaVersion, 13)
            let encoded = try json(draft)
            let item = try XCTUnwrap((encoded["items"] as? [[String: Any]])?.first)
            let metadata = try XCTUnwrap(item["metadata"] as? [String: Any])
            let payload = try XCTUnwrap(metadata["payload"] as? [String: Any])
            XCTAssertEqual(metadata["kind"] as? String, "roundVideo")
            XCTAssertEqual(Set(payload.keys), ["nativeDuration", "plaintextSHA256", "isOneTime"])
            XCTAssertEqual(payload["isOneTime"] as? Bool, once)
            XCTAssertEqual(payload["nativeDuration"] as? Int, 2)
            XCTAssertEqual(try decode(encoded), draft)
            let started = draft.updating(captionInput: .empty, captionAboveMedia: false,
                mediaSpoiler: false, disposition: .submissionStarted)
            XCTAssertTrue(started.isValid); XCTAssertNotEqual(started.revision, draft.revision)
            XCTAssertEqual(started.schemaVersion, 13)
        }
    }

    // Unknown capability payload must refuse rather than silently downgrade.
    func testRoundMetadataRequiresExactDigestAndExplicitBoolean() throws {
        let valid = try fixture(once: true)
        _ = try decode(valid)
        for key in ["nativeDuration", "plaintextSHA256", "isOneTime"] {
            var bad = valid
            mutatePayload(&bad) { $0.removeValue(forKey: key) }
            try assertInvalid(bad)
        }
        for value: Any in [NSNull(), 1, 0, "true", [], ["value": true]] {
            var bad = valid; mutatePayload(&bad) { $0["isOneTime"] = value }; try assertInvalid(bad)
        }
        for value in ["", String(repeating: "A", count: 64), String(repeating: "b", count: 64)] {
            var bad = valid; mutatePayload(&bad) { $0["plaintextSHA256"] = value }; try assertInvalid(bad)
        }
        var unknown = valid; mutatePayload(&unknown) { $0["future"] = true }; try assertInvalid(unknown)
    }

    // Older schemas cannot reinterpret authored round provenance as generic video.
    func testRoundIntentCannotHideInLegacySchemaOrGenericThirteen() throws {
        for version in 1...12 {
            var bad = try fixture(once: false); bad["schemaVersion"] = version; try assertInvalid(bad)
        }
        var generic = try fixture(once: false)
        var items = try XCTUnwrap(generic["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "metadata"); generic["items"] = items
        try assertInvalid(generic)
    }

    // Admission must reject incompatible options before archive capture.
    func testRoundSchemaRefusesCaptionGroupingTransportAndExtraResources() throws {
        for key in ["isGrouped", "captionAboveMedia", "mediaSpoiler"] {
            var bad = try fixture(once: false); bad[key] = true; try assertInvalid(bad)
        }
        var caption = try fixture(once: true)
        caption["captionInput"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            TelegramComposerInput(formattedText: TelegramFormattedText(text: "Synthetic caption"), selection: .init(location: 17, length: 0))))
        try assertInvalid(caption)
        var transport = try fixture(once: false); transport["presentation"] = "file"; try assertInvalid(transport)
        var two = try fixture(once: false)
        let additional = try XCTUnwrap((try fixture(once: false, itemIndex: 1))["items"] as? [[String: Any]])
        two["items"] = try XCTUnwrap(two["items"] as? [[String: Any]]) + additional
        try assertInvalid(two)
        for key in ["videoCover", "originalFile"] {
            var bad = try fixture(once: true)
            var items = try XCTUnwrap(bad["items"] as? [[String: Any]])
            items[0][key] = items[0]["file"]; bad["items"] = items; try assertInvalid(bad)
        }
    }

    private func fixture(once: Bool, itemIndex: Int = 0) throws -> [String: Any] {
        var value = try pendingUploadBatchJSON()
        var item = try XCTUnwrap((value["items"] as? [[String: Any]])?[itemIndex])
        var record = try XCTUnwrap(item["file"] as? [String: Any])
        var attachment = try XCTUnwrap(record["attachment"] as? [String: Any])
        attachment["kind"] = "video"; attachment["name"] = "RoundVideo.mp4"
        record["attachment"] = attachment; item["file"] = record
        item["video"] = ["width": 300, "height": 300, "duration": 1.25, "hasAudio": true, "inCollage": false]
        item["metadata"] = ["kind": "roundVideo", "payload": ["nativeDuration": 2, "plaintextSHA256": try XCTUnwrap(record["plaintextSHA256"] as? String), "isOneTime": once]]
        value["items"] = [item]; value["schemaVersion"] = 13
        value["isGrouped"] = false; value["presentation"] = "media"
        value["captionInput"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TelegramComposerInput.empty))
        value["captionAboveMedia"] = false; value["mediaSpoiler"] = false
        value.removeValue(forKey: "originalDraft")
        return value
    }
    private func mutatePayload(_ value: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        var items = value["items"] as! [[String: Any]], item = items[0]
        var metadata = item["metadata"] as! [String: Any], payload = metadata["payload"] as! [String: Any]
        change(&payload); metadata["payload"] = payload; item["metadata"] = metadata
        items[0] = item; value["items"] = items
    }
    private func decode(_ value: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func json(_ value: TelegramPendingUploadDraft) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func assertInvalid(_ value: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        do { let decoded = try decode(value); XCTAssertFalse(decoded.isValid, file: file, line: line) }
        catch is DecodingError {}
    }
}

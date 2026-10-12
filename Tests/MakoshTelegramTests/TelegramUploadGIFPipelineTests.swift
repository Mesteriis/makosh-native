import XCTest
import Foundation
@testable import MakoshTelegram

func pendingUploadGIFJSON() throws -> [String: Any] {
    var value = try pendingUploadBatchJSON()
    var items = try XCTUnwrap(value["items"] as? [[String: Any]])
    var canonical = try XCTUnwrap(items[0]["file"] as? [String: Any])
    var original = canonical
    var attachment = try XCTUnwrap(canonical["attachment"] as? [String: Any])
    attachment["kind"] = "video"; attachment["name"] = "opaque.mp4"
    canonical["attachment"] = attachment
    attachment["kind"] = "file"; attachment["name"] = "opaque.bin"
    attachment["id"] = "original:00000000-0000-0000-0000-000000000011"
    original["attachment"] = attachment
    original["id"] = "00000000-0000-0000-0000-000000000099"
    items[0]["file"] = canonical; items[0]["originalFile"] = original
    items[0]["video"] = ["width": 32, "height": 16, "duration": 0.75, "hasAudio": false, "inCollage": true]
    items[0]["metadata"] = ["kind": "gif", "payload": ["width": 32, "height": 16,
        "frameDurations": [0.05, 0.2, 0.4], "sourceSHA256": try XCTUnwrap(original["plaintextSHA256"] as? String)]]
    value["items"] = items; value["schemaVersion"] = 10
    value["presentation"] = "media"; value["isGrouped"] = false
    return value
}

final class TelegramUploadGIFPipelineTests: XCTestCase {
    private func decode(_ value: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func metadata(_ value: [String: Any]) throws -> TelegramUploadMetadata {
        try JSONDecoder().decode(TelegramUploadMetadata.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func descriptor() -> [String: Any] {
        ["kind": "gif", "payload": ["width": 32, "height": 16, "frameDurations": [0.05, 0.2, 0.4],
            "sourceSHA256": String(repeating: "a", count: 64)]]
    }

    // Catches dropping source timing/hash provenance from the typed metadata codec.
    func testGIFMetadataRoundTripRetainsLiteralCanvasTimingAndSourceDigest() throws {
        let decoded = try metadata(descriptor())
        XCTAssertTrue(decoded.isValid)
        let bytes = try JSONEncoder().encode(decoded)
        XCTAssertEqual(try JSONDecoder().decode(TelegramUploadMetadata.self, from: bytes), decoded)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(value["kind"] as? String, "gif")
        let payload = try XCTUnwrap(value["payload"] as? [String: Any])
        XCTAssertEqual(payload["width"] as? Int, 32); XCTAssertEqual(payload["height"] as? Int, 16)
        XCTAssertEqual((payload["frameDurations"] as? [NSNumber])?.map(\.floatValue), [Float(0.05), 0.2, 0.4])
        XCTAssertEqual(payload["sourceSHA256"] as? String, String(repeating: "a", count: 64))
    }

    // Catches malformed or cross-kind provenance becoming an admitted typed GIF.
    func testGIFMetadataRejectsMissingNullCrossKindAndUnsafeSourceFacts() throws {
        _ = try metadata(descriptor())
        let good = descriptor(), payload = good["payload"] as! [String: Any]
        for key in ["width", "height", "frameDurations", "sourceSHA256"] {
            var missing = payload; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try metadata(["kind": "gif", "payload": missing]))
            var null = payload; null[key] = NSNull()
            XCTAssertThrowsError(try metadata(["kind": "gif", "payload": null]))
        }
        let bad: [[String: Any]] = [
            ["width": 0], ["height": -1], ["width": 4097], ["width": 4001, "height": 4000],
            ["frameDurations": []], ["frameDurations": [0.0]], ["frameDurations": [-0.1]],
            ["frameDurations": [0.01]], ["frameDurations": [600.1]],
            ["frameDurations": Array(repeating: 0.1, count: 257)],
            ["width": 4000, "height": 4000, "frameDurations": Array(repeating: 0.1, count: 17)],
            ["sourceSHA256": String(repeating: "A", count: 64)], ["sourceSHA256": String(repeating: "a", count: 63)],
            ["duration": 1], ["hasAudio": false]
        ]
        for mutation in bad {
            var changed = payload; changed.merge(mutation) { _, new in new }
            XCTAssertThrowsError(try metadata(["kind": "gif", "payload": changed]), "\(mutation.keys.sorted())")
        }
        for kind in ["audio", "webp", "unknown"] { XCTAssertThrowsError(try metadata(["kind": kind, "payload": payload])) }
        XCTAssertThrowsError(try metadata(["kind": "gif", "payload": payload, "video": NSNull()]))
    }

    // Catches losing the original GIF, its digest binding or the measured MP4 duration on restart.
    func testSchema10RetainsRawGIFAndCanonicalMP4WithSeparateSourceAndVideoFacts() throws {
        let draft = try decode(pendingUploadGIFJSON())
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.schemaVersion, 10)
        let item = draft.items[0]
        XCTAssertEqual(item.file.attachment.kind, "video"); XCTAssertEqual(item.file.attachment.name, "opaque.mp4")
        XCTAssertEqual(item.originalFile?.attachment.name, "opaque.bin")
        XCTAssertNotEqual(item.file.id, item.originalFile?.id)
        XCTAssertEqual(item.video?.duration, 0.75)
        XCTAssertEqual(item.payload(for: .media), item.file)
        XCTAssertEqual(item.payload(for: .file), item.originalFile)
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONEncoder().encode(draft)), draft)
        let rebuilt = try TelegramPendingUploadDraft(id: draft.id, accountID: draft.accountID, chatID: draft.chatID,
            title: draft.title, captionInput: draft.captionInput, originalDraft: nil, replyTarget: nil,
            items: draft.items, isGrouped: false, presentation: .file)
        XCTAssertEqual(rebuilt.schemaVersion, 10); XCTAssertTrue(rebuilt.isValid)
    }

    // Catches a schema downgrade or stripped discriminator reinterpreting GIF as ordinary video.
    func testGIFProvenanceCannotBeDroppedDowngradedOrCombinedWithUnrelatedResources() throws {
        let good = try pendingUploadGIFJSON()
        XCTAssertTrue(try decode(good).isValid)
        func refuses(_ value: [String: Any], _ reason: String) throws {
            do {
                let decoded = try decode(value)
                XCTAssertFalse(decoded.isValid, reason)
            }
            catch is DecodingError {}
        }
        for version in [6, 7, 8, 9] {
            var old = good; old["schemaVersion"] = version
            try refuses(old, "GIF must retain schema10 provenance")
        }
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("missing metadata", { $0.removeValue(forKey: "metadata") }),
            ("null metadata", { $0["metadata"] = NSNull() }),
            ("missing original", { $0.removeValue(forKey: "originalFile") }),
            ("null original", { $0["originalFile"] = NSNull() }),
            ("missing video", { $0.removeValue(forKey: "video") }),
            ("null video", { $0["video"] = NSNull() }),
            ("null cover", { $0["videoCover"] = NSNull() }),
            ("changed source digest", {
                var original = $0["originalFile"] as! [String: Any]
                original["plaintextSHA256"] = String(repeating: "b", count: 64); $0["originalFile"] = original
            }),
            ("wrong canonical name", {
                var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
                attachment["name"] = "different.mp4"; file["attachment"] = attachment; $0["file"] = file
            }),
            ("audio video", {
                var video = $0["video"] as! [String: Any]; video["hasAudio"] = true; $0["video"] = video
            }),
            ("changed canonical canvas", {
                var video = $0["video"] as! [String: Any]; video["width"] = 31; $0["video"] = video
            }),
            ("aliased object", {
                var original = $0["originalFile"] as! [String: Any]
                original["id"] = ($0["file"] as! [String: Any])["id"]; $0["originalFile"] = original
            }),
            ("canonical above codec bound", {
                var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
                let size = 128 * 1024 * 1024 + 1
                file["plaintextByteCount"] = size; file["byteCount"] = size + 96
                attachment["size"] = size; file["attachment"] = attachment; $0["file"] = file
            }),
            ("empty original", {
                var file = $0["originalFile"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
                file["plaintextByteCount"] = 0; file["byteCount"] = 96
                attachment["size"] = 0; file["attachment"] = attachment; $0["originalFile"] = file
            })
        ]
        for (reason, mutation) in mutations {
            var value = good, items = good["items"] as! [[String: Any]]
            mutation(&items[0]); value["items"] = items
            try refuses(value, reason)
        }
    }
}

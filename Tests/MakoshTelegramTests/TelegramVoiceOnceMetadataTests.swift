import Foundation
import XCTest
@testable import MakoshTelegram

final class TelegramVoiceOnceMetadataTests: XCTestCase {
    private let fixtureDigest = String(repeating: "a", count: 64)

    // Normal voice must retain the exact old three-field representation, including explicit null waveform.
    func testNormalMetadataRetainsExactLegacyWireAndFalseDefault() throws {
        for waveform in [nil, Data(repeating: 0, count: 63)] {
            let metadata = TelegramUploadVoiceMetadata(sampleCount: 48_001, plaintextSHA256: fixtureDigest, waveform: waveform)
            let json = try metadataJSON(metadata)
            XCTAssertEqual(Set(json.keys), ["sampleCount", "plaintextSHA256", "waveform"])
            XCTAssertEqual(json["sampleCount"] as? Int, 48_001)
            XCTAssertEqual(json["plaintextSHA256"] as? String, String(repeating: "a", count: 64))
            if let waveform { XCTAssertEqual(json["waveform"] as? String, waveform.base64EncodedString()) }
            else { XCTAssertTrue(json["waveform"] is NSNull) }
            let decoded = try decodeMetadata(json)
            XCTAssertFalse(decoded.isOneTime)
            XCTAssertEqual(decoded.waveform, waveform)
            XCTAssertEqual(decoded.duration, 1)
        }
    }

    // Lost or omitted intent would silently send a one-time recording as an ordinary voice.
    func testTrueIntentEncodesFourthFieldAndRoundtrips() throws {
        let metadata = TelegramUploadVoiceMetadata(sampleCount: 48_001, plaintextSHA256: fixtureDigest, isOneTime: true)
        XCTAssertTrue(metadata.isOneTime)
        XCTAssertNotEqual(metadata, TelegramUploadVoiceMetadata(sampleCount: 48_001, plaintextSHA256: fixtureDigest))
        let json = try metadataJSON(metadata)
        XCTAssertEqual(Set(json.keys), ["sampleCount", "plaintextSHA256", "waveform", "isOneTime"])
        XCTAssertEqual(json["isOneTime"] as? Bool, true)
        XCTAssertTrue(json["waveform"] is NSNull)
        XCTAssertEqual(try decodeMetadata(json), metadata)
        let literal = try decodeMetadata(payload(oneTime: true))
        XCTAssertTrue(literal.isOneTime)
        XCTAssertEqual(literal.sampleCount, 48_001)
    }

    // Explicit false/null or an unknown key must never downgrade an unfamiliar capability to ordinary voice.
    func testMetadataRefusesFalseNullWrongTypesMissingAndUnknownFields() throws {
        _ = try decodeMetadata(payload(oneTime: true))
        for value: Any in [false, NSNull(), 0, 1, "true", "false", [], ["value": true]] {
            var json = payload(oneTime: true); json["isOneTime"] = value
            XCTAssertThrowsError(try decodeMetadata(json), "Accepted invalid one-time value")
        }
        for oneTime in [false, true] {
            let original = payload(oneTime: oneTime)
            for field in ["sampleCount", "plaintextSHA256", "waveform"] {
                var json = original; json.removeValue(forKey: field)
                XCTAssertThrowsError(try decodeMetadata(json), "Missing \(field)")
            }
            var unknown = original; unknown["unexpected"] = true
            XCTAssertThrowsError(try decodeMetadata(unknown))
        }
    }

    // A capability flag cannot relax original PCM count, digest or frozen five-bit waveform validation.
    func testOneTimeMetadataRetainsAllVoiceFactBounds() throws {
        XCTAssertTrue(try decodeMetadata(payload(oneTime: true)).isValid)
        for count in [0, -1, 28_800_001] {
            var json = payload(oneTime: true); json["sampleCount"] = count
            XCTAssertThrowsError(try decodeMetadata(json))
        }
        for digest in ["", String(repeating: "A", count: 64)] {
            var json = payload(oneTime: true); json["plaintextSHA256"] = digest
            XCTAssertThrowsError(try decodeMetadata(json))
        }
        for waveform in [Data(), Data(repeating: 0, count: 62), Data(repeating: 0xff, count: 63)] {
            var json = payload(oneTime: true); json["waveform"] = waveform.base64EncodedString()
            XCTAssertThrowsError(try decodeMetadata(json))
        }
        let invalid = TelegramUploadVoiceMetadata(sampleCount: 0, plaintextSHA256: fixtureDigest, isOneTime: true)
        XCTAssertFalse(invalid.isValid)
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
    }

    // Recovery must retain the new capability with an explicit schema, while ordinary schema11 is unchanged.
    func testSchemaTwelveConstructsAndRoundtripsOnlyOneTimeVoice() throws {
        for oneTime in [false, true] {
            let literal = try decodeDraft(draftFixture(oneTime: oneTime))
            XCTAssertTrue(literal.isValid)
            XCTAssertEqual(literal.schemaVersion, oneTime ? 12 : 11)
            XCTAssertEqual(literal.items[0].metadata?.voice?.isOneTime, oneTime)
            let draft = try TelegramPendingUploadDraft(id: literal.id, accountID: 1, chatID: 42, title: "Synthetic",
                captionInput: .empty, originalDraft: nil, replyTarget: nil, items: literal.items, isGrouped: false, presentation: .file)
            XCTAssertTrue(draft.isValid)
            XCTAssertEqual(draft.schemaVersion, oneTime ? 12 : 11)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
            XCTAssertNil(json["file"])
            XCTAssertEqual((json["items"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual(try decodeDraft(json), draft)
            let updated = draft.updating(captionInput: .empty, captionAboveMedia: false, mediaSpoiler: false, disposition: .submissionStarted)
            XCTAssertTrue(updated.isValid)
            XCTAssertEqual(updated.schemaVersion, oneTime ? 12 : 11)
            XCTAssertEqual(updated.items[0].metadata?.voice?.isOneTime, oneTime)
            XCTAssertNotEqual(updated.revision, draft.revision)
        }
    }

    // Neither a downgrade to an old schema nor an unflagged promotion may change the meaning of recovery.
    func testOneTimeCapabilityCannotHideInSchemaElevenOrOlderOrBeOmittedFromTwelve() throws {
        for version in 1...11 {
            var json = try draftFixture(oneTime: true); json["schemaVersion"] = version
            try assertInvalidDraft(json)
        }
        var promoted = try draftFixture(oneTime: false); promoted["schemaVersion"] = 12
        try assertInvalidDraft(promoted)
        var unknown = try draftFixture(oneTime: true); unknown["schemaVersion"] = 13
        try assertInvalidDraft(unknown)
    }

    // Separate valid receipts isolate the single-voice rule from duplicate-resource rejection.
    func testVoiceSchemasRefuseTwoDistinctOtherwiseValidVoices() throws {
        for oneTime in [false, true] {
            let draft = try decodeDraft(draftFixture(oneTime: oneTime, itemCount: 2))
            XCTAssertEqual(draft.items.count, 2)
            XCTAssertEqual(Set(draft.items.map(\.id)).count, 2)
            XCTAssertEqual(Set(draft.items.map { $0.file.id }).count, 2)
            let identity = TelegramPendingUploadDraft.archiveIdentity(accountID: draft.accountID,
                chatID: draft.chatID, preparationID: draft.id)
            for item in draft.items {
                XCTAssertTrue(item.isValid(identity: identity, legacy: false))
                XCTAssertEqual(item.metadata?.voice?.isOneTime, oneTime)
            }
            XCTAssertFalse(draft.isValid)
        }
    }

    // Schema12 remains a single uncaptained File-transport voice, never an album or a generic-media pointer.
    func testSchemaTwelveRefusesCaptionGroupingSpoilerAndAmbiguousResources() throws {
        let changes: [(inout [String: Any]) throws -> Void] = [
            { $0["isGrouped"] = true }, { $0["captionAboveMedia"] = true }, { $0["mediaSpoiler"] = true },
            { $0["presentation"] = "media" },
            { $0["captionInput"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TelegramComposerInput(formattedText: TelegramFormattedText(text: "caption")))) },
            { $0["items"] = [] },
            { var items = $0["items"] as! [[String: Any]]; items.append(items[0]); $0["items"] = items },
            { var items = $0["items"] as! [[String: Any]]; items[0].removeValue(forKey: "metadata"); $0["items"] = items },
            { var items = $0["items"] as! [[String: Any]]; items[0]["originalFile"] = NSNull(); $0["items"] = items },
            { var items = $0["items"] as! [[String: Any]]; items[0]["videoCover"] = NSNull(); $0["items"] = items },
            { var items = $0["items"] as! [[String: Any]]; items[0]["video"] = NSNull(); $0["items"] = items },
            { $0["file"] = NSNull() }, { $0["videoCover"] = NSNull() }, { $0["video"] = NSNull() },
            { $0.removeValue(forKey: "isGrouped") }, { $0.removeValue(forKey: "presentation") },
            { var items = $0["items"] as! [[String: Any]]; var metadata = items[0]["metadata"] as! [String: Any]; var voice = metadata["payload"] as! [String: Any]; voice["plaintextSHA256"] = String(repeating: "0", count: 64); metadata["payload"] = voice; items[0]["metadata"] = metadata; $0["items"] = items }
        ]
        XCTAssertTrue(try decodeDraft(draftFixture(oneTime: true)).isValid)
        for change in changes {
            var json = try draftFixture(oneTime: true); try change(&json)
            try assertInvalidDraft(json)
        }
    }

    private func payload(oneTime: Bool) -> [String: Any] {
        var json: [String: Any] = ["sampleCount": 48_001, "plaintextSHA256": fixtureDigest, "waveform": NSNull()]
        if oneTime { json["isOneTime"] = true }
        return json
    }

    private func metadataJSON(_ metadata: TelegramUploadVoiceMetadata) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
    }
    private func decodeMetadata(_ json: [String: Any]) throws -> TelegramUploadVoiceMetadata {
        try JSONDecoder().decode(TelegramUploadVoiceMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func decodeDraft(_ json: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func assertInvalidDraft(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        do {
            let draft = try decodeDraft(json)
            XCTAssertFalse(draft.isValid, file: file, line: line)
        } catch is DecodingError {}
    }

    /// Own synthetic encrypted receipt and record from the established fixture, without S3 or account access.
    private func draftFixture(oneTime: Bool, itemCount: Int = 1) throws -> [String: Any] {
        var json = try pendingUploadBatchJSON()
        let sourceItems = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(sourceItems.count, itemCount)
        let items = try sourceItems.prefix(itemCount).map { source in
            var item = source
            let file = try XCTUnwrap(item["file"] as? [String: Any])
            var voice = payload(oneTime: oneTime)
            voice["plaintextSHA256"] = try XCTUnwrap(file["plaintextSHA256"] as? String)
            item["metadata"] = ["kind": "voice", "payload": voice]
            return item
        }
        json["schemaVersion"] = oneTime ? 12 : 11; json["items"] = items
        json["isGrouped"] = false; json["presentation"] = "file"
        json["captionInput"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TelegramComposerInput.empty))
        json["captionAboveMedia"] = false; json["mediaSpoiler"] = false
        json.removeValue(forKey: "originalDraft")
        return json
    }
}

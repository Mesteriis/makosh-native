import Foundation
import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

func recordedVoiceDescriptor(sampleCount: Int = 48_001, hash: String = String(repeating: "a", count: 64),
                             waveform: Data? = nil) throws -> TelegramUploadMetadata {
    try JSONDecoder().decode(TelegramUploadMetadata.self, from: JSONSerialization.data(withJSONObject: [
        "kind": "voice", "payload": ["sampleCount": sampleCount, "plaintextSHA256": hash,
            "waveform": waveform.map { $0.base64EncodedString() } as Any? ?? NSNull()]
    ]))
}

final class TelegramRecordedVoiceSchemaTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        var json = try pendingUploadBatchJSON()
        var item = (json["items"] as! [[String: Any]])[0]
        let record = item["file"] as! [String: Any]
        item["metadata"] = ["kind": "voice", "payload": ["sampleCount": 48_001,
            "plaintextSHA256": record["plaintextSHA256"]!, "waveform": NSNull()]]
        json["schemaVersion"] = 11; json["items"] = [item]; json["isGrouped"] = false
        json["presentation"] = "file"; json.removeValue(forKey: "originalDraft")
        json["captionInput"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TelegramComposerInput.empty))
        json["captionAboveMedia"] = false; json["mediaSpoiler"] = false
        return json
    }
    private func decode(_ json: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // Missing explicit recorded discriminator or schema support loses durable voice semantics.
    func testSchemaElevenPreservesOneExplicitRecordedVoice() throws {
        let draft = try decode(fixture())
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.schemaVersion, 11)
        XCTAssertEqual(try decode(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String: Any]), draft)
        let constructed = try TelegramPendingUploadDraft(id: draft.id, accountID: 1, chatID: 42, title: draft.title,
            captionInput: .empty, originalDraft: nil, replyTarget: nil, items: draft.items, isGrouped: false, presentation: .file)
        XCTAssertEqual(constructed.schemaVersion, 11); XCTAssertTrue(constructed.isValid)
    }

    // Older schemas must not accept an unknown recorded-voice capability under generic metadata.
    func testOlderSchemasCannotHideRecordedVoice() throws {
        for version in 1...10 {
            var value = try fixture(); value["schemaVersion"] = version
            do { let draft = try decode(value); XCTAssertFalse(draft.isValid, "schema\(version)") } catch is DecodingError {}
        }
    }

    // A voice pointer cannot be repurposed into a captioned album, spoiler or visual preparation.
    func testRecordedEnvelopeAndDigestMustMatch() throws {
        let changes: [(inout [String: Any]) throws -> Void] = [
            { $0["isGrouped"] = true }, { $0["captionAboveMedia"] = true }, { $0["mediaSpoiler"] = true },
            { $0["presentation"] = "media" },
            { $0["captionInput"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TelegramComposerInput(formattedText: TelegramFormattedText(text: "caption")))) },
            { var items = $0["items"] as! [[String: Any]]; var second = items[0]; second["id"] = UUID().uuidString; items.append(second); $0["items"] = items },
            { var items = $0["items"] as! [[String: Any]]; var meta = items[0]["metadata"] as! [String: Any]; var payload = meta["payload"] as! [String: Any]; payload["plaintextSHA256"] = String(repeating: "0", count: 64); meta["payload"] = payload; items[0]["metadata"] = meta; $0["items"] = items },
            { var items = $0["items"] as! [[String: Any]]; items[0].removeValue(forKey: "metadata"); $0["items"] = items }
        ]
        for change in changes {
            var value = try fixture(); try change(&value)
            do { let draft = try decode(value); XCTAssertFalse(draft.isValid) } catch is DecodingError {}
        }
    }

    // Exact keys, sample/byte bounds and fixed5-bit waveform layout prevent forged descriptors.
    func testVoiceMetadataRejectsMalformedFacts() throws {
        _ = try recordedVoiceDescriptor()
        for count in [0, -1, 28_800_001] { XCTAssertThrowsError(try recordedVoiceDescriptor(sampleCount: count)) }
        for hash in ["", String(repeating: "A", count: 64)] { XCTAssertThrowsError(try recordedVoiceDescriptor(hash: hash)) }
        for waveform in [Data(), Data(repeating: 0, count: 62), Data(repeating: 255, count: 63)] {
            XCTAssertThrowsError(try recordedVoiceDescriptor(waveform: waveform))
        }
        let descriptor = try recordedVoiceDescriptor(waveform: Data(repeating: 0, count: 63))
        XCTAssertTrue(descriptor.isValid)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as! [String: Any]
        var payload = json["payload"] as! [String: Any]; payload["title"] = "forged"; json["payload"] = payload
        XCTAssertThrowsError(try JSONDecoder().decode(TelegramUploadMetadata.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    private func file(metadata: TelegramUploadMetadata?) -> TelegramUploadFile {
        .init(id: UUID(), name: "Synthetic.bin", size: 42, mode: .file, pixelWidth: nil, pixelHeight: nil,
            url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"), metadata: metadata)
    }

    // Voice uses only Audio(true,...), never FileName/music tags or filename-inferred MIME.
    func testNativeVoiceAttributesHaveNoFilenamePreviewOrStoredSize() throws {
        initializeAccountManagement()
        for waveform in [nil, Data(repeating: 0, count: 63)] {
            let media = try XCTUnwrap(telegramUploadMedia(file(metadata: recordedVoiceDescriptor(waveform: waveform)))?.1.media as? TelegramMediaFile)
            XCTAssertEqual(media.mimeType, "audio/ogg")
            XCTAssertEqual(media.attributes, [.Audio(isVoice: true, duration: 1, title: nil, performer: nil, waveform: waveform)])
            XCTAssertNil(media.size); XCTAssertTrue(media.previewRepresentations.isEmpty); XCTAssertTrue(media.videoThumbnails.isEmpty)
            XCTAssertNil(media.videoCover); XCTAssertNil(media.immediateThumbnailData); XCTAssertTrue(media.alternativeRepresentations.isEmpty)
            let encoder = PostboxEncoder(); encoder.encodeRootObject(media)
            let decoded = try XCTUnwrap(PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())).decodeRootObject() as? TelegramMediaFile)
            XCTAssertEqual(decoded.attributes, media.attributes); XCTAssertNil(decoded.size)
        }
        let generic = try XCTUnwrap(telegramUploadMedia(file(metadata: nil))?.1.media as? TelegramMediaFile)
        XCTAssertEqual(generic.attributes, [.FileName(fileName: "Synthetic.bin")])
    }

    // Plan admission must enforce the same recorded envelope before any native queue mutation.
    func testNativePlanRefusesVoiceAlbumsAndCaptionOptions() throws {
        let item = try TelegramUploadBatchItem(id: UUID(), file: file(metadata: recordedVoiceDescriptor()))
        let empty = try TelegramFormattedText(text: ""), caption = try TelegramFormattedText(text: "caption")
        _ = try TelegramUploadBatchPlan(items: [item], isGrouped: false, caption: empty, presentation: .file)
        for (items, grouped, text, above, spoiler) in [([item], true, empty, false, false),
            ([item], false, caption, false, false), ([item], false, empty, true, false),
            ([item], false, empty, false, true),
            ([item, .init(id: UUID(), file: file(metadata: nil))], false, empty, false, false)] {
            XCTAssertThrowsError(try TelegramUploadBatchPlan(items: items, isGrouped: grouped, caption: text,
                captionAboveMedia: above, mediaSpoiler: spoiler, presentation: .file))
        }
    }
}

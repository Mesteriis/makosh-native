import XCTest
import Foundation
@testable import MakoshTelegram

func pendingUploadVideoFixture(disposition: TelegramPendingUploadDisposition = .prepared) throws -> TelegramPendingUploadDraft {
    try pendingUploadMutating(pendingUploadFixture(disposition: disposition)) {
        $0["schemaVersion"] = 4
        $0["video"] = ["width": 16, "height": 32, "duration": 0.3333333432674408,
            "hasAudio": false, "inCollage": true]
        var file = $0["file"] as! [String: Any]
        var attachment = file["attachment"] as! [String: Any]
        attachment["kind"] = "video"; attachment["name"] = "portrait.MP4"
        file["attachment"] = attachment; $0["file"] = file
    }
}

/// Decoder/validation contract only: media bytes are verified separately by the S3 adapter.
final class TelegramPendingUploadVideoDraftTests: XCTestCase {
    private func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pendingUploadVideoFixture())) as? [String: Any])
    }

    private func decode(_ json: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSchema4VideoRestoresFrozenGeometryDurationAndPreparationChoice() throws {
        let draft = try decode(json())
        XCTAssertTrue(draft.isValid, "Video metadata must be understood before restoring its owned bytes")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        let video = try XCTUnwrap(encoded["video"] as? [String: Any])
        XCTAssertEqual(video["width"] as? Int, 16)
        XCTAssertEqual(video["height"] as? Int, 32)
        XCTAssertEqual(video["duration"] as? Double, 0.3333333432674408)
        XCTAssertEqual(video["hasAudio"] as? Bool, false)
        XCTAssertEqual(video["inCollage"] as? Bool, true)
        XCTAssertEqual(try decode(encoded), draft)
    }

    func testMissingInvalidAndCrossKindVideoMetadataCannotBeRecovered() throws {
        let original = try json()
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("missing video", { $0.removeValue(forKey: "video") }),
            ("future schema", { $0["schemaVersion"] = 5 }),
            ("legacy video", { $0["schemaVersion"] = 3 }),
            ("zero width", { var video = $0["video"] as! [String: Any]; video["width"] = 0; $0["video"] = video }),
            ("excess area", { var video = $0["video"] as! [String: Any]; video["width"] = 8192; video["height"] = 8192; $0["video"] = video }),
            ("zero duration", { var video = $0["video"] as! [String: Any]; video["duration"] = 0; $0["video"] = video }),
            ("unrepresentable receipt duration", { var video = $0["video"] as! [String: Any]; video["duration"] = 1.0 / 3.0; $0["video"] = video }),
            ("excess duration", { var video = $0["video"] as! [String: Any]; video["duration"] = 604801; $0["video"] = video }),
            ("missing preparation choice", { var video = $0["video"] as! [String: Any]; video.removeValue(forKey: "inCollage"); $0["video"] = video }),
            ("file carrying video", { $0["schemaVersion"] = 3; var file = $0["file"] as! [String: Any]; var attachment = file["attachment"] as! [String: Any]; attachment["kind"] = "file"; file["attachment"] = attachment; $0["file"] = file }),
            ("photo carrying video", { $0["schemaVersion"] = 3; var file = $0["file"] as! [String: Any]; var attachment = file["attachment"] as! [String: Any]; attachment["kind"] = "photo"; file["attachment"] = attachment; $0["file"] = file }),
            ("non-video name", { var file = $0["file"] as! [String: Any]; var attachment = file["attachment"] as! [String: Any]; attachment["name"] = "audio.wav"; file["attachment"] = attachment; $0["file"] = file })
        ]
        for (reason, mutate) in mutations {
            var value = original; mutate(&value)
            do { let decoded = try decode(value); XCTAssertFalse(decoded.isValid, reason) }
            catch is DecodingError {} // Missing/ill-typed required fields are also incompatible data.
        }
    }

    func testLegacyFileNamedMP4RemainsAnOrdinaryFile() throws {
        for version in [1, 2, 3] {
            var value = try json()
            value["schemaVersion"] = version; value.removeValue(forKey: "video")
            var file = value["file"] as! [String: Any]
            var attachment = file["attachment"] as! [String: Any]
            attachment["kind"] = "file"; file["attachment"] = attachment; value["file"] = file
            let draft = try decode(value)
            XCTAssertTrue(draft.isValid)
            XCTAssertEqual(draft.file.attachment.kind, "file")
            XCTAssertEqual(draft.file.attachment.name, "portrait.MP4")
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
            XCTAssertNil(encoded["video"])
        }
    }
}

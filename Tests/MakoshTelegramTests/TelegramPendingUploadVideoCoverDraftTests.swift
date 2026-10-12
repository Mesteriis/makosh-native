import XCTest
import Foundation
@testable import MakoshTelegram

func pendingUploadVideoCoverFixture(disposition: TelegramPendingUploadDisposition = .prepared) throws -> TelegramPendingUploadDraft {
    try JSONDecoder().decode(TelegramPendingUploadDraft.self,
        from: JSONSerialization.data(withJSONObject: pendingUploadVideoCoverJSON(disposition: disposition)))
}

private func pendingUploadVideoCoverJSON(disposition: TelegramPendingUploadDisposition = .prepared) throws -> [String: Any] {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pendingUploadVideoFixture(disposition: disposition))) as? [String: Any])
        var file = try XCTUnwrap(value["file"] as? [String: Any]), attachment = try XCTUnwrap(file["attachment"] as? [String: Any])
        file["id"] = UUID().uuidString
        attachment["id"] = "video-cover"; attachment["kind"] = "photo"; attachment["name"] = "cover.jpg"
        file["attachment"] = attachment
        value["schemaVersion"] = 5
        value["videoCover"] = ["file": file, "width": 160, "height": 320]
        return value
}

final class TelegramPendingUploadVideoCoverDraftTests: XCTestCase {
    // A schema4 reader cannot silently drop the cover and resend different media.
    func testSchema5RoundTripRetainsSeparateCoverAndFrozenVideo() throws {
        let draft = try pendingUploadVideoCoverFixture()
        XCTAssertTrue(draft.isValid)
        let bytes = try JSONEncoder().encode(draft)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(encoded["schemaVersion"] as? Int, 5)
        let cover = try XCTUnwrap(encoded["videoCover"] as? [String: Any])
        XCTAssertEqual(cover["width"] as? Int, 160); XCTAssertEqual(cover["height"] as? Int, 320)
        let file = try XCTUnwrap(cover["file"] as? [String: Any])
        let attachment = try XCTUnwrap(file["attachment"] as? [String: Any])
        XCTAssertEqual(attachment["id"] as? String, "video-cover")
        XCTAssertEqual(attachment["kind"] as? String, "photo")
        XCTAssertNotEqual(file["id"] as? String, draft.file.id.uuidString)
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: bytes), draft)
    }

    // Catches cross-account pointers, malformed or uncommitted archive records,
    // and older schemas carrying a cover that their readers would discard.
    func testCoverCannotBeDroppedMisScopedOrAttachedToNonVideo() throws {
        let original = try pendingUploadVideoCoverJSON()
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("missing cover", { $0.removeValue(forKey: "videoCover") }),
            ("old schema", { $0["schemaVersion"] = 4 }),
            ("no video", { $0.removeValue(forKey: "video") }),
            ("zero width", { var c = $0["videoCover"] as! [String: Any]; c["width"] = 0; $0["videoCover"] = c }),
            ("excess height", { var c = $0["videoCover"] as! [String: Any]; c["height"] = 321; $0["videoCover"] = c }),
            ("foreign account", { var c = $0["videoCover"] as! [String: Any], f = c["file"] as! [String: Any], identity = f["identity"] as! [String: Any]; identity["accountID"] = "9"; f["identity"] = identity; c["file"] = f; $0["videoCover"] = c }),
            ("wrong attachment", { var c = $0["videoCover"] as! [String: Any], f = c["file"] as! [String: Any], a = f["attachment"] as! [String: Any]; a["id"] = "prepared"; f["attachment"] = a; c["file"] = f; $0["videoCover"] = c }),
            ("wrong kind", { var c = $0["videoCover"] as! [String: Any], f = c["file"] as! [String: Any], a = f["attachment"] as! [String: Any]; a["kind"] = "file"; f["attachment"] = a; c["file"] = f; $0["videoCover"] = c }),
            ("unsafe name", { var c = $0["videoCover"] as! [String: Any], f = c["file"] as! [String: Any], a = f["attachment"] as! [String: Any]; a["name"] = "../cover.jpg"; f["attachment"] = a; c["file"] = f; $0["videoCover"] = c }),
            ("unstored", { var c = $0["videoCover"] as! [String: Any], f = c["file"] as! [String: Any]; f["state"] = "pending"; c["file"] = f; $0["videoCover"] = c }),
            ("wrong digest", { var c = $0["videoCover"] as! [String: Any], f = c["file"] as! [String: Any]; f["plaintextSHA256"] = "invalid"; c["file"] = f; $0["videoCover"] = c }),
            ("oversize", { var c = $0["videoCover"] as! [String: Any], f = c["file"] as! [String: Any], a = f["attachment"] as! [String: Any]; f["plaintextByteCount"] = 1_048_577; a["size"] = 1_048_577; f["attachment"] = a; c["file"] = f; $0["videoCover"] = c })
        ]
        for (reason, change) in mutations {
            var changed = original; change(&changed)
            let decoded = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertFalse(decoded.isValid, reason)
        }
    }
}

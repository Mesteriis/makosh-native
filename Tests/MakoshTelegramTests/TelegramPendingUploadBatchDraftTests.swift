import XCTest
import Foundation
@testable import MakoshTelegram

/// Metadata fixtures use real envelope receipts and synthetic content only.
func pendingUploadBatchJSON() throws -> [String: Any] {
    let first = try pendingUploadFixture()
    let second = try pendingUploadFixture(id: first.id)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(second)) as? [String: Any])
    let ids = ["00000000-0000-0000-0000-000000000011", "00000000-0000-0000-0000-000000000012"]
    let sources = [json, secondJSON]
    let items: [[String: Any]] = try sources.enumerated().map { index, source in
        var file = try XCTUnwrap(source["file"] as? [String: Any])
        var attachment = try XCTUnwrap(file["attachment"] as? [String: Any])
        attachment["id"] = "prepared:" + ids[index]
        attachment["name"] = index == 0 ? "first.txt" : "second.txt"
        file["attachment"] = attachment
        return ["id": ids[index], "file": file]
    }
    json["schemaVersion"] = 6; json["items"] = items; json["isGrouped"] = true
    json.removeValue(forKey: "file"); json.removeValue(forKey: "video"); json.removeValue(forKey: "videoCover")
    return json
}

func pendingUploadBatchFixture() throws -> TelegramPendingUploadDraft {
    try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: pendingUploadBatchJSON()))
}

final class TelegramPendingUploadBatchDraftTests: XCTestCase {
    func testRawPhotoSourceCannotBeDroppedOrDowngradedIntoAnOlderBatch() throws {
        var json = try pendingUploadBatchJSON(), items = json["items"] as! [[String: Any]]
        var original = items[0]["file"] as! [String: Any]
        var attachment = original["attachment"] as! [String: Any]
        attachment["id"] = "original:00000000-0000-0000-0000-000000000011"
        attachment["name"] = "original.png"; original["attachment"] = attachment
        original["id"] = "00000000-0000-0000-0000-000000000099"
        var prepared = items[0]["file"] as! [String: Any], photo = prepared["attachment"] as! [String: Any]
        photo["kind"] = "photo"; photo["name"] = "original.jpg"; prepared["attachment"] = photo
        items[0]["file"] = prepared; items[0]["originalFile"] = original
        json["items"] = items; json["schemaVersion"] = 7
        let decode: ([String: Any]) throws -> TelegramPendingUploadDraft = {
            try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        let draft = try decode(json)
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONEncoder().encode(draft)), draft)
        var downgraded = json; downgraded["schemaVersion"] = 6
        XCTAssertFalse(try decode(downgraded).isValid, "An older reader must not silently discard original references")
        var missing = items; missing[0].removeValue(forKey: "originalFile")
        var invalid = json; invalid["items"] = missing
        XCTAssertFalse(try decode(invalid).isValid)
        var duplicate = original; duplicate["id"] = prepared["id"]
        var aliased = items; aliased[0]["originalFile"] = duplicate; invalid["items"] = aliased
        XCTAssertFalse(try decode(invalid).isValid, "Original and normalized payload cannot share an archive object ID")
        var foreign = original, identity = original["identity"] as! [String: Any]
        identity["conversationID"] = "43"; foreign["identity"] = identity
        var swapped = items; swapped[0]["originalFile"] = foreign; invalid["items"] = swapped
        XCTAssertFalse(try decode(invalid).isValid)
    }

    func testBatchAcceptanceRetainsEveryUniqueLocalMessageIDAndRejectsPartialReceipts() throws {
        var json = try pendingUploadBatchJSON()
        json["disposition"] = ["acceptedBatch": ["messageIDs": [
            ["peerID": 42, "namespace": 1, "id": 1], ["peerID": 42, "namespace": 1, "id": 2]
        ]]]
        let draft: TelegramPendingUploadDraft
        do { draft = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json)) }
        catch { return XCTFail("A complete ordered batch receipt must survive decoding: \(error)") }
        XCTAssertTrue(draft.isValid)
        for ids in [
            [["peerID": 42, "namespace": 1, "id": 1]],
            [["peerID": 42, "namespace": 1, "id": 1], ["peerID": 42, "namespace": 1, "id": 1]],
            [["peerID": 42, "namespace": 1, "id": 1], ["peerID": 43, "namespace": 1, "id": 2]],
            [["peerID": 42, "namespace": 1, "id": 1], ["peerID": 42, "namespace": 0, "id": 2]]
        ] {
            json["disposition"] = ["acceptedBatch": ["messageIDs": ids]]
            let invalid = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertFalse(invalid.isValid)
        }
    }

    // Catches silently reading/writing just the first file of an ordered set.
    func testSchema6RoundTripRetainsEveryOrderedResourceAndCommonCaption() throws {
        let json = try pendingUploadBatchJSON()
        let decoded: TelegramPendingUploadDraft
        do { decoded = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json)) }
        catch { XCTFail("The ordered schema6 preparation must decode instead of requiring a single top-level file"); return }
        XCTAssertTrue(decoded.isValid)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let items = try XCTUnwrap(encoded["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, ["00000000-0000-0000-0000-000000000011", "00000000-0000-0000-0000-000000000012"])
        XCTAssertEqual(items.compactMap { ($0["file"] as? [String: Any])?["attachment"] as? [String: Any] }.compactMap { $0["name"] as? String }, ["first.txt", "second.txt"])
        XCTAssertEqual(encoded["isGrouped"] as? Bool, true)
        XCTAssertNil(encoded["file"], "There must be one canonical representation, without an ambiguous first-file fallback")
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    // Old readers must reject an upgraded set, not ignore its second file.
    func testLegacySchemaCannotCarryAnIgnoredBatch() throws {
        let first = try pendingUploadFixture()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        legacy["items"] = try pendingUploadBatchJSON()["items"]
        do {
            let decoded = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertFalse(decoded.isValid, "A legacy preparation with batch data must fail closed")
        } catch is DecodingError {}
    }

    // The second item must receive the same validation as the first one.
    func testMalformedDuplicateOrForeignSecondResourceCannotBeAdmitted() throws {
        let mutations: [(String, (inout [[String: Any]]) -> Void)] = [
            ("duplicate item", { $0[1] = $0[0] }),
            ("wrong stable identity", { $0[1]["id"] = "00000000-0000-0000-0000-000000000013" }),
            ("foreign preparation", { var f = $0[1]["file"] as! [String: Any], i = f["identity"] as! [String: Any]; i["messageID"] = "pending-upload:foreign"; f["identity"] = i; $0[1]["file"] = f }),
            ("unstored", { var f = $0[1]["file"] as! [String: Any]; f["state"] = "pending"; $0[1]["file"] = f }),
            ("bad digest", { var f = $0[1]["file"] as! [String: Any]; f["plaintextSHA256"] = "invalid"; $0[1]["file"] = f }),
            ("unsafe name", { var f = $0[1]["file"] as! [String: Any], a = f["attachment"] as! [String: Any]; a["name"] = "../second.txt"; f["attachment"] = a; $0[1]["file"] = f }),
            ("duplicate archive object", { var f = $0[1]["file"] as! [String: Any]; f["id"] = ($0[0]["file"] as! [String: Any])["id"]; $0[1]["file"] = f })
        ]
        for (reason, mutate) in mutations {
            var json = try pendingUploadBatchJSON(), items = json["items"] as! [[String: Any]]
            mutate(&items); json["items"] = items
            do {
                let decoded = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
                XCTAssertFalse(decoded.isValid, reason)
            } catch is DecodingError {}
        }
    }

    func testCoveredVideoKeepsItsOwnItemBoundCoverAndAllFileOptionsAreChecked() throws {
        var json = try pendingUploadBatchJSON(), items = json["items"] as! [[String: Any]]
        let video = try pendingUploadVideoCoverFixture()
        var source = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(video)) as? [String: Any])
        var file = source["file"] as! [String: Any], cover = source["videoCover"] as! [String: Any]
        var coverFile = cover["file"] as! [String: Any]
        let identity = (items[0]["file"] as! [String: Any])["identity"]
        file["identity"] = identity; coverFile["identity"] = identity
        var attachment = file["attachment"] as! [String: Any], coverAttachment = coverFile["attachment"] as! [String: Any]
        attachment["id"] = "prepared:00000000-0000-0000-0000-000000000012"
        coverAttachment["id"] = "video-cover:00000000-0000-0000-0000-000000000012"
        file["attachment"] = attachment; coverFile["attachment"] = coverAttachment; cover["file"] = coverFile
        source["file"] = file; items[1]["file"] = file; items[1]["video"] = source["video"]; items[1]["videoCover"] = cover
        json["items"] = items
        let decoded: TelegramPendingUploadDraft
        do { decoded = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json)) }
        catch { XCTFail("A batch can retain an independently scoped video cover"); return }
        XCTAssertTrue(decoded.isValid)
        for flag in ["captionAboveMedia", "mediaSpoiler"] {
            var flagged = json; flagged[flag] = true
            let invalid = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: flagged))
            XCTAssertFalse(invalid.isValid, "Visual-only options cannot silently apply to the first ordinary file")
        }
        coverAttachment["id"] = "video-cover:00000000-0000-0000-0000-000000000011"
        coverFile["attachment"] = coverAttachment; cover["file"] = coverFile; items[1]["videoCover"] = cover; json["items"] = items
        XCTAssertFalse(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json)).isValid)
    }

    func testBatchCannotUseSingleMessageAcceptanceOrAmbiguousLegacyFields() throws {
        var json = try pendingUploadBatchJSON()
        json["disposition"] = ["accepted": ["localMessageID": "42:0:1"]]
        do {
            let draft = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertFalse(draft.isValid, "One receipt must never acknowledge an entire album")
        } catch is DecodingError {}
        json = try pendingUploadBatchJSON()
        json["file"] = (json["items"] as! [[String: Any]])[0]["file"]
        do {
            let draft = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertFalse(draft.isValid, "Two competing resource representations are incompatible data")
        } catch is DecodingError {}
    }
}

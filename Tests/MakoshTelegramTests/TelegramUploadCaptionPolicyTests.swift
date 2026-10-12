import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramUploadCaptionPolicyTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        var json = try pendingUploadSourceFactsJSON()
        json["schemaVersion"] = 19
        let items = json["items"] as! [[String: Any]]
        json["captionPolicy"] = ["maximumUTF16Count": 2048, "items": items.map {
            ["itemID": $0["id"]!, "fileCanHaveCaption": true]
        }]
        return json
    }

    private func decode(_ json: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self,
            from: JSONSerialization.data(withJSONObject: json))
    }

    private func refused(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        do { let draft = try decode(json); XCTAssertFalse(draft.isValid, file: file, line: line) }
        catch { }
    }

    // Catches losing the account's frozen limit/capability binding after an encrypted pointer round trip.
    func testSchema19RoundTripsAnExplicitFrozenPolicyAndPreservesRawEditorInput() throws {
        var json = try fixture()
        let input = try TelegramComposerInput(formattedText: .init(text: " **caption😀** "))
        json["captionInput"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        let draft: TelegramPendingUploadDraft
        do { draft = try decode(json) }
        catch { return XCTFail("New explicit caption policy must decode: \(error)") }
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.schemaVersion, 19)
        XCTAssertEqual(draft.captionRules, .current); XCTAssertEqual(draft.captionInput, input)
        let encoded = try JSONEncoder().encode(draft)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(wire["captionPolicy"] as? NSDictionary, json["captionPolicy"] as? NSDictionary)
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: encoded), draft)
        let changed = draft.updating(captionInput: .empty, captionAboveMedia: false,
            mediaSpoiler: false, disposition: .prepared)
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as? [String: Any])
        XCTAssertEqual(updated["captionPolicy"] as? NSDictionary, json["captionPolicy"] as? NSDictionary)
    }

    // Catches applying the new projection to a frozen old schema or admitting an unversioned policy field.
    func testOlderSchemasRefusePolicyWithoutChangingTheirExistingOutput() throws {
        for version in [14, 15, 17] {
            var old = try pendingUploadSourceFactsJSON(); old["schemaVersion"] = version
            let draft = try decode(old); XCTAssertTrue(draft.isValid)
            let raw = try TelegramFormattedText(text: " **literal** ")
            XCTAssertEqual(try draft.captionRules.projection(raw).text,
                version == 14 ? " **literal** " : "**literal**")
            old["captionPolicy"] = try fixture()["captionPolicy"]
            XCTAssertThrowsError(try decode(old))
            old["captionPolicy"] = NSNull()
            XCTAssertThrowsError(try decode(old))
        }
    }

    // Catches a malformed limit or capabilities being borrowed from another item or order.
    func testSchema19RefusesMalformedOrIncompletePolicyBindings() throws {
        let base = try fixture()
        for action in 0..<9 {
            var json = base, policy = json["captionPolicy"] as! [String: Any]
            var items = policy["items"] as! [[String: Any]]
            switch action {
            case 0: policy["maximumUTF16Count"] = 0
            case 1: policy["maximumUTF16Count"] = Double(Int32.max) + 1
            case 2: policy["maximumUTF16Count"] = 2048.5
            case 3: policy["futurePolicy"] = true
            case 4: items.removeLast()
            case 5: items.reverse()
            case 6: items[0]["itemID"] = UUID().uuidString
            case 7: items[0]["fileCanHaveCaption"] = NSNull()
            default: items[0]["futureCapability"] = true
            }
            policy["items"] = items; json["captionPolicy"] = policy
            try refused(json)
        }
        var absent = base; absent.removeValue(forKey: "captionPolicy"); try refused(absent)
        var noFacts = base, items = noFacts["items"] as! [[String: Any]]
        items[0].removeValue(forKey: "sourceFacts"); noFacts["items"] = items; try refused(noFacts)
    }
    // Catches selecting the new projection without a durable versioned policy.
    func testCurrentProjectionRequiresExplicitPolicyAtDraftConstruction() throws {
        let old = try decode(pendingUploadSourceFactsJSON())
        XCTAssertThrowsError(try TelegramPendingUploadDraft(id: old.id, accountID: old.accountID, chatID: old.chatID,
            title: old.title, captionInput: old.captionInput, originalDraft: nil, replyTarget: nil,
            items: old.items, isGrouped: old.isGrouped, presentation: old.presentation, captionRules: .current, mediaRules: .reference))
    }

}

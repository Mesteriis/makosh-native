import XCTest
import Foundation
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramForumUploadTests: XCTestCase {
    private func wire(_ draft: TelegramPendingUploadDraft) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    }
    private func decode(_ value: [String: Any]) -> TelegramPendingUploadDraft? {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(TelegramPendingUploadDraft.self, from: bytes)
    }
    func testTopicPreparationRestartsAndUpdatesWithoutPromotingOriginalResourcePolicy() throws {
        for base in [try pendingUploadFixture(), try pendingUploadVideoFixture(), try pendingUploadBatchFixture()] {
            var value = try wire(base)
            value["schemaVersion"] = 21; value["resourceSchemaVersion"] = base.resourceSchemaVersion
            value["threadID"] = 7
            if var original = value["originalDraft"] as? [String: Any] {
                original["schemaVersion"] = 6; original["threadID"] = 7; value["originalDraft"] = original
            }
            let restored = decode(value)
            XCTAssertNotNil(restored, "A versioned topic preparation must decode")
            guard let restored else { continue }
            XCTAssertTrue(restored.isValid)
            XCTAssertEqual(restored.items, base.items)
            XCTAssertEqual(restored.captionRules, base.captionRules)
            let edited = restored.updating(captionInput: restored.captionInput, captionAboveMedia: false,
                mediaSpoiler: false, disposition: .submissionStarted)
            XCTAssertTrue(edited.isValid)
            XCTAssertEqual(try wire(edited)["threadID"] as? Int, 7)
            XCTAssertEqual(try wire(edited)["schemaVersion"] as? Int, 21)
            XCTAssertEqual(try wire(edited)["resourceSchemaVersion"] as? Int, base.resourceSchemaVersion)
        }
    }
    func testUnversionedTopicIdentityIsRefusedWithoutChangingLegacyWire() throws {
        let base = try pendingUploadBatchFixture()
        XCTAssertNil(try wire(base)["threadID"])
        var hidden = try wire(base); hidden["threadID"] = 7
        XCTAssertFalse(decode(hidden)?.isValid == true, "Older wire cannot silently drop thread identity")
        for thread in [0, -1, Int64(Int32.max) + 1] {
            var value = try wire(base); value["schemaVersion"] = 21
            value["resourceSchemaVersion"] = base.resourceSchemaVersion; value["threadID"] = thread
            XCTAssertFalse(decode(value)?.isValid == true)
        }
    }
    func testNativeBuilderRetainsSelectedThreadForMediaAndLeadingTextWithoutReply() throws {
        let target = TelegramUploadTarget(accountID: 1, chatID: 2, title: "Forum", selectedThreadID: 7)
        let file = TelegramUploadFile(id: UUID(), name: "synthetic.txt", size: 3, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: URL(fileURLWithPath: "/synthetic/payload"),
            directory: URL(fileURLWithPath: "/synthetic"))
        let reference = try XCTUnwrap(telegramUploadMedia(file)).1
        for media in [Optional(reference), nil] {
            let message = telegramUploadMessage(caption: try .init(text: "Topic text"), reference: media,
                target: target, replySource: nil)
            XCTAssertNotNil(message)
            guard case let .message(_, _, _, _, thread, reply, _, _, _, _)? = message else { continue }
            XCTAssertEqual(thread, 7); XCTAssertNil(reply)
        }
    }
}

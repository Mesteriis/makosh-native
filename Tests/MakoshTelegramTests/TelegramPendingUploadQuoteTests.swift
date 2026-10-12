import XCTest
import Foundation
import TelegramCore
@testable import MakoshTelegram

final class TelegramPendingUploadQuoteTests: XCTestCase {
    private func quoted(_ value: TelegramPendingUploadDraft) throws -> TelegramPendingUploadDraft {
        let quote = try XCTUnwrap(TelegramReplyQuote(source: try .init(text: "a selected 😀 z"), selection: .init(location: 2, length: 11)))
        let target = TelegramComposerReplyTarget(peerID: value.chatID, namespace: Namespaces.Message.Cloud, messageID: 3, quote: quote)
        let original = TelegramComposerDraft(accountID: value.accountID, chatID: value.chatID, input: value.captionInput, replyTarget: target)
        if value.schemaVersion < 6 {
            return TelegramPendingUploadDraft(id: value.id, accountID: value.accountID, chatID: value.chatID, title: value.title,
                captionInput: value.captionInput, originalDraft: original, replyTarget: target,
                file: value.file, video: value.video, videoCover: value.videoCover)
        }
        return try TelegramPendingUploadDraft(id: value.id, accountID: value.accountID, chatID: value.chatID, title: value.title,
            captionInput: value.captionInput, originalDraft: original, replyTarget: target, items: value.items,
            isGrouped: value.isGrouped, presentation: value.schemaVersion >= 8 ? value.presentation : nil,
            captionRules: value.captionRules, mediaRules: value.mediaRules, archive: value.archive, captionPolicy: value.captionPolicy)
    }
    private func json(_ value: TelegramPendingUploadDraft) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func decode(_ value: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func refused(_ value: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        do { let decoded = try decode(value); XCTAssertFalse(decoded.isValid, file: file, line: line) }
        catch { }
    }
    private func currentPolicy() throws -> TelegramPendingUploadDraft {
        var wire = try pendingUploadSourceFactsJSON(); wire["schemaVersion"] = 19
        wire["captionPolicy"] = ["maximumUTF16Count": 2048, "items": (wire["items"] as! [[String: Any]]).map {
            ["itemID": $0["id"]!, "fileCanHaveCaption": true]
        }]
        return try decode(wire)
    }
    func testQuotedPreparationVersionsTheQuoteWithoutPromotingItsResourceOrCaptionPolicy() throws {
        for base in [try pendingUploadFixture(), try pendingUploadVideoFixture(), try pendingUploadVideoCoverFixture(),
                     try pendingUploadBatchFixture(), try currentPolicy()] {
            let draft = try quoted(base), wire = try json(draft)
            XCTAssertTrue(draft.isValid)
            XCTAssertEqual(draft.schemaVersion, 20)
            XCTAssertEqual(wire["resourceSchemaVersion"] as? Int, base.schemaVersion)
            XCTAssertEqual(draft.captionRules, base.captionRules)
            XCTAssertEqual(draft.mediaRules, base.mediaRules)
            XCTAssertEqual(draft.captionPolicy, base.captionPolicy)
            XCTAssertEqual(draft.items, base.items)
            XCTAssertEqual(try decode(wire), draft)
            let edited = draft.updating(captionInput: draft.captionInput, captionAboveMedia: false, mediaSpoiler: false, disposition: .submissionStarted)
            XCTAssertTrue(edited.isValid)
            XCTAssertEqual(edited.schemaVersion, 20)
            XCTAssertEqual(try json(edited)["resourceSchemaVersion"] as? Int, base.schemaVersion)
        }
    }
    func testLegacyPreparationCannotSilentlyAcquireQuotedTargetOrUnversionedResourcePolicy() throws {
        let base = try pendingUploadBatchFixture(), draft = try quoted(base)
        var downgraded = try json(draft)
        downgraded["schemaVersion"] = base.schemaVersion
        downgraded.removeValue(forKey: "resourceSchemaVersion")
        refused(downgraded)
        var hiddenPolicy = try json(base); hiddenPolicy["resourceSchemaVersion"] = 19
        refused(hiddenPolicy)
        for version in [0, 1, 2, 20, 21] {
            var invalid = try json(draft); invalid["schemaVersion"] = 20; invalid["resourceSchemaVersion"] = version
            refused(invalid)
        }
    }
}

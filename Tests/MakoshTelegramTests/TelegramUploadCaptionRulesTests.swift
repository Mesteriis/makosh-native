import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramUploadCaptionRulesTests: XCTestCase {
    // Catches sending padding/newlines that the reference removes from plain input.
    func testPlainCaptionProjectionTrimsEdgesWithoutChangingEditorInput() throws {
        let raw = try TelegramFormattedText(text: " \t\r\n\u{00a0}Exact 😀\u{2003}\n ")
        let plan = try TelegramUploadBatchPlan(items: batchPlanItems(1), isGrouped: false, caption: raw)
        XCTAssertEqual(plan.messages[0].caption.text, "Exact 😀")
        XCTAssertEqual(raw.text, " \t\r\n\u{00a0}Exact 😀\u{2003}\n ")
    }

    // Catches losing formatting or leaving offsets attached to discarded prefix whitespace.
    func testFormattedCaptionProjectionTrimsEdgesAndShiftsUTF16Offsets() throws {
        let raw = try TelegramFormattedText(text: " \n😀 x \t", entities: [.init(offset: 2, length: 2, kind: .bold)])
        let plan = try TelegramUploadBatchPlan(items: batchPlanItems(2), isGrouped: false, caption: raw)
        XCTAssertEqual(plan.messages[0].caption.text, "😀 x")
        XCTAssertEqual(plan.messages[0].caption.entities, [.init(offset: 0, length: 2, kind: .bold)])
        XCTAssertEqual(raw.entities, [.init(offset: 2, length: 2, kind: .bold)])
    }

    // Catches manufacturing a leading empty message and the wrong native ACK cardinality.
    func testPlainWhitespaceDoesNotCreateLeadingMessage() throws {
        let plan = try TelegramUploadBatchPlan(items: batchPlanItems(2), isGrouped: false,
            caption: TelegramFormattedText(text: " \t\n\u{00a0}"))
        XCTAssertEqual(plan.messages.count, 2)
        XCTAssertTrue(plan.messages.allSatisfy { $0.itemID != nil && $0.caption.text.isEmpty })
    }

    // Catches applying a caption limit to discarded padding rather than the actual outgoing plain text.
    func testLimitUsesProjectedUTF16AndRejectsOversizedBody() throws {
        let raw = try TelegramFormattedText(text: String(repeating: " ", count: 1200) + "😀" + String(repeating: "\n", count: 1200))
        let plan = try TelegramUploadBatchPlan(items: batchPlanItems(1), isGrouped: false, caption: raw)
        XCTAssertEqual(plan.messages[0].caption.text, "😀")
        let formatted = try TelegramFormattedText(text: raw.text, entities: [.init(offset: 1200, length: 2, kind: .italic)])
        let formattedPlan = try TelegramUploadBatchPlan(items: batchPlanItems(1), isGrouped: false, caption: formatted)
        XCTAssertEqual(formattedPlan.messages[0].caption.text, "😀")
        XCTAssertEqual(formattedPlan.messages[0].caption.entities, [.init(offset: 0, length: 2, kind: .italic)])
        let oversized = try TelegramFormattedText(text: String(repeating: "😀", count: 513), entities: [.init(offset: 0, length: 2, kind: .bold)])
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: batchPlanItems(1), isGrouped: false, caption: oversized))
    }

    // Catches normalized line separators shifting one-unit entity offsets, or changing the platform reference whitespace set.
    func testProjectionNormalizesUnicodeSeparatorsUsingPlatformWhitespace() throws {
        let raw = try TelegramFormattedText(text: " \u{200b}a\u{2028}b\u{fffc}c ", entities: [.init(offset: 4, length: 3, kind: .italic)])
        let plan = try TelegramUploadBatchPlan(items: batchPlanItems(1), isGrouped: false, caption: raw)
        XCTAssertEqual(plan.messages[0].caption.text, "a\nb\nc")
        XCTAssertEqual(plan.messages[0].caption.entities, [.init(offset: 2, length: 3, kind: .italic)])
    }

    // Catches invalid zero-length or out-of-range entities when formatting crosses discarded edges.
    func testProjectionClipsNestedEntitiesAndDropsEmptyIntersections() throws {
        let raw = try TelegramFormattedText(text: "  😀 x  ", entities: [
            .init(offset: 0, length: 8, kind: .bold), .init(offset: 0, length: 2, kind: .italic),
            .init(offset: 2, length: 2, kind: .underline), .init(offset: 6, length: 2, kind: .code)])
        let plan = try TelegramUploadBatchPlan(items: batchPlanItems(1), isGrouped: false, caption: raw)
        XCTAssertEqual(plan.messages[0].caption.text, "😀 x")
        XCTAssertEqual(plan.messages[0].caption.entities, [.init(offset: 0, length: 4, kind: .bold), .init(offset: 0, length: 2, kind: .underline)])
    }

    // Unsupported provenance remains a veto even if its entire text is trimmed away.
    func testProjectionDoesNotLaunderUnsupportedEntitiesAtTrimmedEdges() throws {
        for kind: TelegramTextEntityKind in [.unknown, .custom(type: 8), .customEmoji(stickerPack: nil, fileID: 9)] {
            let raw = try TelegramFormattedText(text: " x", entities: [.init(offset: 0, length: 1, kind: kind)])
            XCTAssertThrowsError(try TelegramUploadBatchPlan(items: batchPlanItems(1), isGrouped: false, caption: raw))
        }
    }

    // The reference length preflight does not erase object placeholders before counting.
    func testOversizedObjectPlaceholderInputCannotBypassReferencePreflight() throws {
        let raw = try TelegramFormattedText(text: String(repeating: "\u{fffc}", count: 1025) + "x")
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: batchPlanItems(1), isGrouped: false, caption: raw))
    }

    // Catches a sticker silently losing text because the server does not accept its caption.
    func testSingleWebPUsesLeadingTextAndAnEmptyStickerCaption() throws {
        let file = TelegramUploadFile(id: UUID(), name: "sticker.webp", size: 16, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: URL(fileURLWithPath: "/synthetic/sticker.webp"),
            directory: URL(fileURLWithPath: "/synthetic"), metadata: .webP(.init(width: 32, height: 48)))
        let item = TelegramUploadBatchItem(id: UUID(), file: file)
        let plan = try TelegramUploadBatchPlan(items: [item], isGrouped: false,
            caption: TelegramFormattedText(text: " Sticker 😀 "), presentation: .file)
        XCTAssertEqual(plan.messages.count, 2)
        XCTAssertNil(plan.messages.first?.itemID); XCTAssertEqual(plan.messages.first?.caption.text, "Sticker 😀")
        XCTAssertEqual(plan.messages.last?.itemID, item.id); XCTAssertEqual(plan.messages.last?.caption.text, "")
    }

    // A generic payload still maps its original-name WebP MIME into a captionless native file.
    func testGenericWebPMIMEUsesLeadingTextWithoutTypedStickerMetadata() throws {
        let file = TelegramUploadFile(id: UUID(), name: "unsupported.webp", size: 16, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: URL(fileURLWithPath: "/synthetic/unsupported.webp"),
            directory: URL(fileURLWithPath: "/synthetic"))
        let id = UUID(), facts = TelegramUploadSourceFacts(itemID: id, role: .prepared, name: file.name,
            byteCount: 16, plaintextSHA256: String(repeating: "a", count: 64), selectionMIME: "image/webp",
            image: .rejected, grouping: .ordinary)
        let plan = try TelegramUploadBatchPlan(items: [.init(id: id, file: file, sourceFacts: facts)], isGrouped: false,
            caption: TelegramFormattedText(text: "Generic WebP"), presentation: .file)
        XCTAssertEqual(plan.messages.count, 2)
        XCTAssertNil(plan.messages.first?.itemID); XCTAssertEqual(plan.messages.last?.caption.text, "")
    }

    // Catches applying changed placement semantics to an old durable preparation or refusing new schema15.
    func testNewSourcePreparationUsesStrictCaptionVersionAndPreservesRawInput() throws {
        var json = try pendingUploadSourceFactsJSON()
        let raw = try TelegramComposerInput(formattedText: TelegramFormattedText(text: " \t\n"))
        json["captionInput"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(raw))
        json["isGrouped"] = false
        let legacy = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.isValid); XCTAssertEqual(legacy.schemaVersion, 14)
        let new = try TelegramPendingUploadDraft(id: legacy.id, accountID: legacy.accountID, chatID: legacy.chatID,
            title: legacy.title, captionInput: raw, originalDraft: nil, replyTarget: nil,
            items: legacy.items, isGrouped: false, presentation: .file)
        XCTAssertEqual(new.schemaVersion, 15); XCTAssertTrue(new.isValid)
        XCTAssertEqual(new.captionInput, raw)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(new)) as? [String: Any])
        wire["schemaVersion"] = 15
        do {
            let decoded = try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: wire))
            XCTAssertTrue(decoded.isValid); XCTAssertEqual(decoded.captionInput, raw)
        } catch { XCTFail("New strict caption schema must survive the codec: \(error)") }
    }
}

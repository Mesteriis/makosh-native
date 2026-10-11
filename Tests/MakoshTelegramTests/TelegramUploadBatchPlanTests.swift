import XCTest
import Foundation
@testable import MakoshTelegram

func batchPlanItems(_ count: Int, mode: TelegramUploadMode = .photo) -> [TelegramUploadBatchItem] {
    (0..<count).map { index in
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
        return .init(id: id, file: TelegramUploadFile(id: UUID(), name: mode == .file ? "item.pdf" : "item.jpg",
            size: 16, mode: mode, pixelWidth: mode == .photo ? 16 : nil, pixelHeight: mode == .photo ? 16 : nil,
            url: URL(fileURLWithPath: "/synthetic/payload"), directory: URL(fileURLWithPath: "/synthetic")))
    }
}

final class TelegramUploadBatchPlanTests: XCTestCase {
    func testGroupedBoundariesPreserveItemOrderAndRepeatCaptionAtReferencePositions() throws {
        let caption = try TelegramFormattedText(text: "Caption 😀", entities: [.init(offset: 0, length: 7, kind: .bold)])
        for (count, groups, photoCaptions, fileCaptions): (Int, [Int?], [Int], [Int]) in [
            (1, [nil], [0], [0]),
            (10, Array(repeating: 0, count: 10), [0], [9]),
            (11, Array(repeating: 0, count: 10) + [1], [0, 10], [9, 10]),
            (20, Array(repeating: 0, count: 10) + Array(repeating: 1, count: 10), [0, 10], [9, 19]),
            (21, Array(repeating: 0, count: 10) + Array(repeating: 1, count: 10) + [2], [0, 10, 20], [9, 19, 20])
        ] {
            for mode: TelegramUploadMode in [.photo, .file] {
                let items = batchPlanItems(count, mode: mode)
                let plan = try TelegramUploadBatchPlan(items: items, isGrouped: true, caption: caption)
                XCTAssertEqual(plan.messages.map(\.itemID), items.map { Optional($0.id) })
                XCTAssertEqual(plan.messages.map(\.groupIndex), groups)
                let positions = mode == .photo ? photoCaptions : fileCaptions
                XCTAssertEqual(plan.messages.enumerated().compactMap { $0.element.caption.text.isEmpty ? nil : $0.offset }, positions)
                for (index, message) in plan.messages.enumerated() {
                    XCTAssertEqual(message.caption.text, positions.contains(index) ? "Caption 😀" : "")
                    XCTAssertEqual(message.caption.entities.count, positions.contains(index) ? 1 : 0,
                        "Do not attach out-of-range original entities to empty media captions")
                }
            }
        }
    }

    func testSeparateMediaUsesOneLeadingFormattedTextMessageAndNoGroupingKeys() throws {
        let items = batchPlanItems(11), caption = try TelegramFormattedText(text: "Exact 😀",
            entities: [.init(offset: 0, length: 5, kind: .italic)])
        let plan = try TelegramUploadBatchPlan(items: items, isGrouped: false, caption: caption,
            captionAboveMedia: true, mediaSpoiler: true)
        XCTAssertEqual(plan.messages.count, 12)
        XCTAssertNil(plan.messages[0].itemID); XCTAssertEqual(plan.messages[0].caption, caption)
        XCTAssertFalse(plan.messages[0].captionAboveMedia); XCTAssertFalse(plan.messages[0].mediaSpoiler)
        XCTAssertEqual(plan.messages.dropFirst().map(\.itemID), items.map { Optional($0.id) })
        XCTAssertTrue(plan.messages.allSatisfy { $0.groupIndex == nil })
        XCTAssertTrue(plan.messages.dropFirst().allSatisfy { $0.caption.text.isEmpty && $0.caption.entities.isEmpty &&
            $0.captionAboveMedia && $0.mediaSpoiler })
        let empty = try TelegramUploadBatchPlan(items: items, isGrouped: false, caption: TelegramFormattedText(text: ""))
        XCTAssertEqual(empty.messages.count, 11); XCTAssertNotNil(empty.messages[0].itemID)
    }

    func testInvalidBatchCannotSilentlyMixWholeListModesOrDuplicateStableIDs() throws {
        let caption = try TelegramFormattedText(text: "")
        let photo = batchPlanItems(1)[0], file = batchPlanItems(2, mode: .file)[1]
        for items in [[], [photo, photo], [photo, file]] {
            XCTAssertThrowsError(try TelegramUploadBatchPlan(items: items, isGrouped: true, caption: caption))
        }
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: [file], isGrouped: false, caption: caption, mediaSpoiler: true))
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: [file], isGrouped: false, caption: caption, captionAboveMedia: true))
    }
}

import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramUploadPlaceholderTests: XCTestCase {
    // Catches treating grouping as one preview row past the reference's ten-item boundary.
    func testMediaPlaceholderFollowsReferencePreviewRows() {
        for (count, grouped, expected) in [(0, false, false), (1, false, true), (2, false, false),
                                           (1, true, true), (10, true, true), (11, true, false),
                                           (20, true, false), (21, true, false)] {
            XCTAssertEqual(TelegramUploadCaptionRules.usesCaptionPlaceholder(items: batchPlanItems(count),
                presentation: .media, isGrouped: grouped), expected, "count=\(count), grouped=\(grouped)")
        }
    }

    // File mode keeps individual rows even when the outgoing files are grouped; Archive has one ZIP row.
    func testFileAndArchivePlaceholderUseTheirOwnRowShapes() {
        for (presentation, count, grouped, expected) in [(TelegramUploadPresentation.file, 1, false, true),
            (.file, 2, false, false), (.file, 2, true, false), (.file, 11, true, false),
            (.archive, 2, false, true), (.archive, 11, false, true)] {
            XCTAssertEqual(TelegramUploadCaptionRules.usesCaptionPlaceholder(items: batchPlanItems(count, mode: .file),
                presentation: presentation, isGrouped: grouped), expected)
        }
    }

    // Catches using a caption hint for a single file whose native media cannot accept captions.
    func testSingleWebPFileRequiresCommentWithTypedOrSourceMIMEEvidence() {
        let cases: [(TelegramUploadMetadata?, String?)] = [(.webP(.init(width: 32, height: 48)), nil), (nil, "image/webp")]
        for (metadata, mime) in cases {
            let id = UUID(), file = TelegramUploadFile(id: id, name: "synthetic.webp", size: 16, mode: .file,
                pixelWidth: nil, pixelHeight: nil, url: URL(fileURLWithPath: "/synthetic/source"),
                directory: URL(fileURLWithPath: "/synthetic"), metadata: metadata)
            let facts = mime.map { TelegramUploadSourceFacts(itemID: id, role: .prepared, name: file.name,
                byteCount: 16, plaintextSHA256: String(repeating: "a", count: 64), selectionMIME: $0,
                image: .rejected, grouping: .ordinary) }
            XCTAssertFalse(TelegramUploadCaptionRules.usesCaptionPlaceholder(
                items: [.init(id: id, file: file, sourceFacts: facts)], presentation: .file, isGrouped: false))
        }
    }
}

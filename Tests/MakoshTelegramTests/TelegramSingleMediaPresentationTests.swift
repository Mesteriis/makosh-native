import XCTest
@testable import MakoshTelegram

final class TelegramSingleMediaPresentationTests: XCTestCase {
    private func attachment(_ width: Int32? = nil, _ height: Int32? = nil,
                            kind: TelegramAttachmentKind = .photo, playback: TelegramPlaybackKind? = nil) -> TelegramAttachment {
        .init(id: "synthetic", kind: kind, name: "Synthetic", byteCount: nil, mimeType: nil,
            hasPreview: true, canDownload: true, playback: playback,
            dimensions: width.flatMap { w in height.flatMap { .init(width: w, height: $0) } })
    }

    func testPhotoFitsReferenceBoundsWithoutCroppingPortraitAndReservesCaptionWidth() {
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(640, 400), availableWidth: 600), CGSize(width: 320, height: 200))
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(160, 320), availableWidth: 600), CGSize(width: 160, height: 320))
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(160, 320), availableWidth: 600, hasCaption: true), CGSize(width: 320, height: 320))
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(20, 10), availableWidth: 600), CGSize(width: 200, height: 100))
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(), availableWidth: 600), CGSize(width: 320, height: 320))
    }

    func testVideoUsesLandscapeWidthAndPortraitBoundsWithoutInventingMissingDimensions() {
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(1920, 1080, kind: .file, playback: .video), availableWidth: 600), CGSize(width: 420, height: 236))
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(100, 200, kind: .file, playback: .video), availableWidth: 600), CGSize(width: 160, height: 320))
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(100, 100, kind: .file, playback: .video), availableWidth: 600, hasCaption: true), CGSize(width: 320, height: 300))
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(kind: .file, playback: .video), availableWidth: 600), CGSize(width: 300, height: 300))
        XCTAssertEqual(TelegramSingleMediaPresentation.size(attachment(20, 10, kind: .file, playback: .video), availableWidth: 600), CGSize(width: 320, height: 320))
    }

    func testNarrowWindowsAndExtremeDimensionsRemainFiniteAndWithinAvailableWidth() throws {
        for width in [16.0, 80, 180, 320, 600, 16_384] {
            for item in [attachment(1, Int32.max), attachment(Int32.max, 1), attachment(20, 10),
                         attachment(1920, 1080, kind: .file, playback: .video)] {
                let size = try XCTUnwrap(TelegramSingleMediaPresentation.size(item, availableWidth: width, hasCaption: true))
                XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                XCTAssertGreaterThan(size.width, 0); XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.width, width); XCTAssertLessThanOrEqual(size.height, 420)
            }
        }
        for width in [Double.nan, .infinity, -1, 0, 16_385] {
            XCTAssertNil(TelegramSingleMediaPresentation.size(attachment(640, 400), availableWidth: width))
        }
    }

    func testNonvisualFilesAudioRoundVideoAndUnsupportedKeepTheirExistingRenderers() {
        for item in [attachment(kind: .file), attachment(kind: .file, playback: .voice),
                     attachment(kind: .file, playback: .audio), attachment(kind: .file, playback: .roundVideo),
                     attachment(kind: .unsupported)] {
            XCTAssertNil(TelegramSingleMediaPresentation.size(item, availableWidth: 600))
        }
    }
}

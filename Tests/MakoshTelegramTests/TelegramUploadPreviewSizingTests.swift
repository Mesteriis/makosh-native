import XCTest
@testable import MakoshTelegram

final class TelegramUploadPreviewSizingTests: XCTestCase {
    // Catches the former200pt cap and120pt floor on separate photo rows.
    func testSeparatePhotosUseTheirReferenceHeight() {
        XCTAssertEqual(size(.photo, 320, 640), CGSize(width: 160, height: 320))
        XCTAssertEqual(size(.photo, 320, 320), CGSize(width: 320, height: 320))
        XCTAssertEqual(size(.photo, 640, 160), CGSize(width: 320, height: 80))
        XCTAssertEqual(size(.photo, 40, 80), CGSize(width: 100, height: 200))
        XCTAssertEqual(size(.photo, 320, 640, availableWidth: 180), CGSize(width: 100, height: 180))
    }

    // Separate landscape video may use420pt; a collage singleton stays within320pt.
    func testSeparateVideosKeepTheirOwnBoundsWithoutChangingCollageSingletons() {
        let video = file(.video, 1920, 1080)
        XCTAssertEqual(TelegramSingleMediaPresentation.uploadSize(video, availableWidth: 480), CGSize(width: 420, height: 236))
        XCTAssertEqual(TelegramUploadPreviewMosaic.layout(items: [.init(id: UUID(), file: video)], width: 480, scale: 2).dimensions,
            CGSize(width: 320, height: 180))
        XCTAssertEqual(size(.video, 100, 200), CGSize(width: 160, height: 320))
        XCTAssertEqual(size(.video, nil, nil), CGSize(width: 300, height: 300))
        XCTAssertEqual(size(.video, 20, 10), CGSize(width: 320, height: 320))
    }

    // A filename or dimensions must never turn a File or recorded round into an ordinary visual row.
    func testFilesAndRecordedRoundKeepTheirExistingRenderers() {
        XCTAssertNil(size(.file, 320, 640))
        let video = TelegramUploadVideoMetadata(width: 300, height: 300, duration: 1, hasAudio: true, inCollage: false)
        let round = TelegramUploadFile(id: UUID(), name: "RoundVideo.mp4", size: 42, mode: .video,
            pixelWidth: 300, pixelHeight: 300, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"),
            video: video, metadata: .roundVideo(.init(nativeDuration: 1, plaintextSHA256: String(repeating: "a", count: 64))))
        XCTAssertNil(TelegramSingleMediaPresentation.uploadSize(round, availableWidth: 480))
    }

    func testMissingDimensionsUseReferenceFallbackAndInvalidWidthsRefuseLayout() {
        XCTAssertEqual(size(.photo, nil, nil), CGSize(width: 320, height: 320))
        for width in [Double.nan, .infinity, -1, 0, 16_385] {
            XCTAssertNil(size(.photo, 320, 640, availableWidth: width))
        }
    }

    private func size(_ mode: TelegramUploadMode, _ width: Int32?, _ height: Int32?, availableWidth: Double = 480) -> CGSize? {
        TelegramSingleMediaPresentation.uploadSize(file(mode, width, height), availableWidth: availableWidth)
    }

    private func file(_ mode: TelegramUploadMode, _ width: Int32?, _ height: Int32?) -> TelegramUploadFile {
        .init(id: UUID(), name: "Synthetic.png", size: 42, mode: mode, pixelWidth: width, pixelHeight: height,
            url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
    }
}

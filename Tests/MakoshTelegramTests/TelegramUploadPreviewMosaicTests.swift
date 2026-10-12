import XCTest
@testable import MakoshTelegram

final class TelegramUploadPreviewMosaicTests: XCTestCase {
    // Reference preview packing uses square ratios even when the source images are portrait or wide.
    func testTwoPreviewTilesIgnoreSourceAspectWhileHistoryRetainsIt() {
        let items = photos(2, width: 40, height: 80)
        XCTAssertEqual(frames(items: items, width: 320, scale: 2), [
            CGRect(x: 0, y: 0, width: 158, height: 158), CGRect(x: 162, y: 0, width: 158, height: 158)])
        XCTAssertEqual(frames(items: photos(2, width: 400, height: 100), width: 320, scale: 2), [
            CGRect(x: 0, y: 0, width: 158, height: 158), CGRect(x: 162, y: 0, width: 158, height: 158)])
        XCTAssertEqual(TelegramAlbumMosaic.frames(aspects: [0.5, 0.5], width: 320).first?.height, 316)
    }

    // Catches accidentally reusing the history's three/four-member arrangement.
    func testThreeAndFourUseReferencePreviewShapesAndPixelFlooring() {
        XCTAssertEqual(frames(items: photos(3), width: 320, scale: 2), [
            CGRect(x: 0, y: 0, width: 320, height: 208), CGRect(x: 0, y: 212, width: 158, height: 108),
            CGRect(x: 162, y: 212, width: 158, height: 108)])
        XCTAssertEqual(frames(items: photos(4), width: 320, scale: 2), [
            CGRect(x: 0, y: 0, width: 189.5, height: 320), CGRect(x: 193.5, y: 0, width: 104, height: 104),
            CGRect(x: 193.5, y: 108, width: 104, height: 104), CGRect(x: 193.5, y: 216, width: 104, height: 104)])
    }

    // Hand-derived row counts for the reference's square-ratio preview score at width320.
    func testFiveThroughTenPreserveItemOrderInReferenceRows() {
        for (count, rowCounts) in [(5, [2, 3]), (6, [2, 2, 2]), (7, [2, 2, 3]),
                                   (8, [2, 3, 3]), (9, [3, 3, 3]), (10, [2, 2, 3, 3])] {
            let frames = frames(items: photos(count), width: 320, scale: 2)
            XCTAssertEqual(frames.count, count)
            let rows = frames.reduce(into: [[CGRect]]()) { rows, frame in
                if rows.last?.last?.minY == frame.minY { rows[rows.count - 1].append(frame) }
                else { rows.append([frame]) }
            }
            XCTAssertEqual(rows.map(\.count), rowCounts)
            XCTAssertTrue(rows.allSatisfy { $0.map(\.minX) == $0.map(\.minX).sorted() })
            for (index, frame) in frames.enumerated() {
                XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
                XCTAssertLessThanOrEqual(frame.maxX, 320)
                for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
            }
        }
    }

    // The minimum row height changes the selected partition on narrow previews.
    func testNarrowPreviewUsesTheReferenceMinimumHeightPenalty() {
        let narrow = frames(items: photos(5), width: 192, scale: 2)
        XCTAssertEqual(narrow.map(\.minY), [0, 196, 196, 294, 294])
        let wider = frames(items: photos(5), width: 218, scale: 2)
        XCTAssertEqual(wider.map(\.minY), [0, 0, 111, 111, 111])
    }

    // Rounded component extents must not shift a full-width grid by half a pixel.
    func testBoundingDimensionsAreFlooredBeforeIndividualComponents() {
        let nine = TelegramUploadPreviewMosaic.layout(items: photos(9), width: 420, scale: 2)
        XCTAssertEqual(nine.dimensions.width, 420)
        XCTAssertEqual(nine.frames.map(\.maxX).max(), 419.5)
        let four = TelegramUploadPreviewMosaic.layout(items: photos(4), width: 320, scale: 2)
        XCTAssertEqual(four.dimensions, CGSize(width: 297.5, height: 320))
        XCTAssertEqual(four.frames.map(\.maxX).max(), 297.5)
    }

    // A trailing singleton uses media sizing instead of stretching to the full album width.
    func testSingletonFitsReferenceMediaBoundsAndRejectsInvalidInputs() {
        XCTAssertEqual(frames(items: photos(1, width: 40, height: 80), width: 420, scale: 2),
            [CGRect(x: 0, y: 0, width: 100, height: 200)])
        XCTAssertTrue(frames(items: [], width: 320, scale: 2).isEmpty)
        XCTAssertTrue(frames(items: photos(11), width: 320, scale: 2).isEmpty)
        XCTAssertTrue(frames(items: batchPlanItems(2, mode: .file), width: 320, scale: 2).isEmpty)
        for width in [Double.nan, .infinity, 0, 16_385] {
            XCTAssertTrue(frames(items: photos(2), width: width, scale: 2).isEmpty)
        }
        for scale in [Double.nan, .infinity, 0, -1] {
            XCTAssertTrue(frames(items: photos(2), width: 320, scale: scale).isEmpty)
        }
    }

    private func frames(items: [TelegramUploadBatchItem], width: Double, scale: Double) -> [CGRect] {
        TelegramUploadPreviewMosaic.layout(items: items, width: width, scale: scale).frames
    }

    private func photos(_ count: Int, width: Int32 = 100, height: Int32 = 100) -> [TelegramUploadBatchItem] {
        batchPlanItems(count).map { item in
            .init(id: item.id, file: .init(id: item.file.id, name: item.file.name, size: item.file.size, mode: .photo,
                pixelWidth: width, pixelHeight: height, url: item.file.url, directory: item.file.directory))
        }
    }
}

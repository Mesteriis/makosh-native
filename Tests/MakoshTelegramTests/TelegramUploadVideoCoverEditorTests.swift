import XCTest
import CoreGraphics
import ImageIO
@testable import MakoshTelegram

@MainActor final class TelegramUploadVideoCoverEditorTests: XCTestCase {
    // Catches selecting the image's ratio for a standard video ratio, or
    // approximating a nonstandard video ratio where the reference uses Original.
    func testInitialCropFollowsReferencePresetOrOriginalAndStartsCentered() throws {
        let crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 1200, height: 600),
            videoSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(crop.rect.origin.x, 0.25, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.origin.y, 0.21875, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.width, 0.5, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.height, 0.5625, accuracy: 0.000001)
        let original = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 1200, height: 600),
            videoSize: CGSize(width: 16, height: 32))
        XCTAssertEqual(original.rect, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    // Catches drag/resize escaping the admitted image or changing the fixed
    // aspect. The opposite corner must stay anchored during resize.
    func testMoveAndResizeClampToImageWithoutChangingPixelAspect() throws {
        var crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 800, height: 400),
            videoSize: CGSize(width: 16, height: 9))
        crop.resize(by: CGSize(width: 0.75, height: 0.75), corner: .bottomRight)
        XCTAssertEqual(crop.rect.origin.x, 0.25, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.origin.y, 0.21875, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.maxY, 1, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.width * 800 / (crop.rect.height * 400), 16.0 / 9, accuracy: 0.000001)
        crop.move(by: CGSize(width: 1, height: -1))
        XCTAssertEqual(crop.rect.maxX, 1, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.minY, 0, accuracy: 0.000001)
        let before = crop.rect
        crop.move(by: CGSize(width: CGFloat.nan, height: 0))
        crop.resize(by: CGSize(width: CGFloat.infinity, height: 0), corner: .topLeft)
        XCTAssertEqual(crop.rect, before)
        crop.resize(by: CGSize(width: 100, height: 100), corner: .topLeft)
        XCTAssertGreaterThan(crop.rect.width, 0); XCTAssertGreaterThan(crop.rect.height, 0)
        XCTAssertLessThanOrEqual(crop.rect.maxX, 1); XCTAssertLessThanOrEqual(crop.rect.maxY, 1)
    }

    // Reference resizing derives height from the dragged width. A vertical
    // motion alone must not enlarge the crop or move its opposite corner.
    func testVerticalCornerMotionKeepsWidthAndAspectSelectionUnchanged() throws {
        for corner in [TelegramUploadVideoCoverCrop.Corner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            var crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 800, height: 400),
                videoSize: CGSize(width: 16, height: 9))
            let before = crop.rect
            crop.resize(by: CGSize(width: 0, height: 0.1), corner: corner)
            XCTAssertEqual(crop.rect, before)
        }
    }

    // A 40pt width on a 400pt fitted view is 10% regardless of source pixels.
    // Portrait height is derived from aspect; horizontal crop height may be
    // below 40pt. The opposite corner remains fixed at the minimum.
    func testCornerResizeUsesFittedPointMinimumAndOppositeAnchor() throws {
        var crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 800, height: 400),
            videoSize: CGSize(width: 16, height: 9))
        crop.resize(by: CGSize(width: -10, height: -10), corner: .bottomRight,
            canvasSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(crop.rect.minX, 0.25, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.minY, 0.21875, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.width, 0.1, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.height, 0.1125, accuracy: 0.000001)
    }

    // Double click returns to the largest centered crop of the selected ratio,
    // rather than the initial centered square-derived region or a free aspect.
    func testSelectingMaximumBoundsKeepsPresetAndOriginalAspect() throws {
        var standard = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 800, height: 400),
            videoSize: CGSize(width: 16, height: 9))
        standard.selectMaximumBounds()
        XCTAssertEqual(standard.rect.minX, 1.0 / 18, accuracy: 0.000001)
        XCTAssertEqual(standard.rect.minY, 0, accuracy: 0.000001)
        XCTAssertEqual(standard.rect.width, 8.0 / 9, accuracy: 0.000001)
        XCTAssertEqual(standard.rect.height, 1, accuracy: 0.000001)
        var original = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 800, height: 400),
            videoSize: CGSize(width: 2, height: 1))
        original.selectMaximumBounds()
        XCTAssertEqual(original.rect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // Two-pass point fitting must neither enlarge a small source nor drop the
    // ceil-rounded orthogonal point when the opposite axis becomes limiting.
    func testFittedImageGeometryKeepsSmallSourcesAndRoundsReducedExtent() {
        XCTAssertEqual(TelegramUploadVideoCoverCrop.fittedImageSize(CGSize(width: 40, height: 80),
            in: CGSize(width: 552, height: 352)), CGSize(width: 40, height: 80))
        XCTAssertEqual(TelegramUploadVideoCoverCrop.fittedImageSize(CGSize(width: 1001, height: 601),
            in: CGSize(width: 552, height: 352)), CGSize(width: 552, height: 332))
        XCTAssertEqual(TelegramUploadVideoCoverCrop.fittedImageSize(CGSize(width: 1001, height: 601),
            in: CGSize(width: 552, height: 300)), CGSize(width: 499, height: 300))
    }

    // Initial square/aspect correction uses fitted points, including the
    // orthogonal ceil. Using source pixels leaves this selection0.579421pt narrow.
    func testInitialSelectionUsesFittedCanvasBeforePresetAspect() throws {
        var crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 1001, height: 601),
            videoSize: CGSize(width: 16, height: 9))
        crop.fitInitialSelection(canvasSize: CGSize(width: 552, height: 332))
        XCTAssertEqual(crop.rect.minX, 110.0 / 552, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.minY, 72.625 / 332, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.width, 332.0 / 552, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.height, 186.75 / 332, accuracy: 0.000001)
    }

    // The reference floors the initial square side and Original follows the
    // fitted canvas aspect. Invalid geometry must not reset an existing crop.
    func testInitialOriginalSelectionFloorsSquareAndRejectsInvalidCanvas() throws {
        var crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 1001, height: 601),
            videoSize: CGSize(width: 2, height: 1))
        crop.fitInitialSelection(canvasSize: CGSize(width: 552, height: 331.5))
        XCTAssertEqual(crop.rect.width, 331.0 / 552, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.height, 331.0 / 552, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.minX, 221.0 / 1104, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.minY, 221.0 / 1104, accuracy: 0.000001)
        crop.move(by: CGSize(width: 0.1, height: -0.1))
        let existing = crop
        for canvas in [CGSize.zero, CGSize(width: CGFloat.nan, height: 1), CGSize(width: 1, height: 0.5)] {
            crop.fitInitialSelection(canvasSize: canvas)
            XCTAssertEqual(crop, existing)
        }
    }

    // Round the two pointer positions separately: ceil(100.9)-ceil(100.2)
    // is zero, while rounding their difference would move the selection.
    func testPointerMoveRoundsPositionsBeforeComputingTranslation() throws {
        var crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 800, height: 400),
            videoSize: CGSize(width: 16, height: 9))
        crop.move(from: CGPoint(x: 100.2, y: 43.8), to: CGPoint(x: 100.9, y: 44.2),
            canvasSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(crop.rect.minX, 0.25, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.minY, 0.22375, accuracy: 0.000001)
    }

    // Corner movement uses the actual canvas pointer, including its initial
    // grab offset, rather than translating the old corner by a drag delta.
    func testCornerPointerIsCeiledAndClampedInCanvasCoordinates() throws {
        var crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 800, height: 400),
            videoSize: CGSize(width: 16, height: 9))
        crop.resize(to: CGPoint(x: 350.2, y: 150), corner: .bottomRight,
            canvasSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(crop.rect.minX, 0.25, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.minY, 0.21875, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.width, 0.6275, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.height, 0.7059375, accuracy: 0.000001)
    }

    func testInvalidImageOrVideoSizeCannotEnterEditor() {
        for invalid in [CGSize.zero, CGSize(width: -1, height: 1), CGSize(width: CGFloat.nan, height: 1),
                        CGSize(width: 1, height: CGFloat.infinity)] {
            XCTAssertThrowsError(try TelegramUploadVideoCoverCrop(imageSize: invalid, videoSize: CGSize(width: 16, height: 9)))
            XCTAssertThrowsError(try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 40, height: 80), videoSize: invalid))
        }
    }

    // Catches applying a new picker file in place of the image shown in the
    // editor, leaking its temporary stage, or deleting the user's source.
    func testEditorSelectionUsesOwnedSnapshotAndReleasesOnlyItsStage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cover.jpg")
        try writeUploadVideoCoverFixture(source)
        let original = try Data(contentsOf: source)
        let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
        defer { try? TelegramUploadVideoCoverIO.discardSelection(selection) }
        XCTAssertEqual(selection.preview.image.width, 40); XCTAssertEqual(selection.preview.image.height, 80)
        let cover = try await TelegramUploadVideoCoverIO.stage(selection, crop: CGRect(x: 0, y: 0.25, width: 1, height: 0.5))
        defer { try? TelegramUploadFileIO.discard(cover.imageFile) }
        XCTAssertEqual(cover.width, 40); XCTAssertEqual(cover.height, 40)
        try TelegramUploadVideoCoverIO.discardSelection(selection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selection.file.directory.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        do {
            _ = try await TelegramUploadVideoCoverIO.stage(selection, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTFail("Released editor snapshot cannot be applied")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }

    func testApplyingEditorRejectsSameSizeReplacementOfDisplayedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cover.jpg")
        try writeUploadVideoCoverFixture(source)
        var original = try Data(contentsOf: source)
        original.append(Data(repeating: 0, count: 1024))
        try original.write(to: source)
        let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
        defer { try? TelegramUploadVideoCoverIO.discardSelection(selection) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImageDestinationLossyCompressionQuality: 0.1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertLessThanOrEqual(bytes.length, Int(selection.file.size))
        var replacement = bytes as Data
        replacement.append(Data(repeating: 0, count: max(0, Int(selection.file.size) - replacement.count)))
        XCTAssertEqual(Int64(replacement.count), selection.file.size)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(replacement as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        try replacement.write(to: selection.file.url)
        do {
            let unexpected = try await TelegramUploadVideoCoverIO.stage(selection, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
            try TelegramUploadFileIO.discard(unexpected.imageFile)
            XCTFail("Apply must use the snapshot displayed by the editor")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }
}

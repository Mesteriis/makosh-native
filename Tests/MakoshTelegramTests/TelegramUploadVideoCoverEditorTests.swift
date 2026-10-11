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

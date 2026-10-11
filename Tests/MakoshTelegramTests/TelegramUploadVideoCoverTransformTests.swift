import XCTest
import CoreGraphics
import ImageIO
import CryptoKit
@testable import MakoshTelegram

@MainActor final class TelegramUploadVideoCoverTransformTests: XCTestCase {
    // Catches photo normalization replacing the original bytes, reducing editor
    // geometry or losing detail before the user has selected a crop.
    func testSelectionRetainsOriginalImageBytesAndFullOrientedResolution() async throws {
        let source = try imageSource(width: 4000, height: 1000, orientation: 6)
        let bytes = try Data(contentsOf: source)
        let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
        defer { try? TelegramUploadVideoCoverIO.discardSelection(selection) }
        XCTAssertEqual(try Data(contentsOf: selection.file.url), bytes)
        XCTAssertEqual(selection.file.size, Int64(bytes.count))
        XCTAssertEqual(selection.preview.image.width, 1000)
        XCTAssertEqual(selection.preview.image.height, 4000)
        XCTAssertEqual(selection.preview.originalSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try FileManager.default.removeItem(at: source)
        let cover = try await TelegramUploadVideoCoverIO.stage(selection, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadVideoCoverIO.discardCover(cover) }
        XCTAssertEqual(cover.width, 80); XCTAssertEqual(cover.height, 320)
    }

    // The raw editor snapshot must retain the image byte cap rather than
    // inheriting the larger document limit after bypassing photo normalization.
    func testEditorRejectsOversizedSourceBeforeDecode() async throws {
        let source = try imageSource(width: 40, height: 80)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 20 * 1024 * 1024 + 1)
        try handle.close()
        do {
            let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
            try TelegramUploadVideoCoverIO.discardSelection(selection)
            XCTFail("Editor source exceeded its bounded input")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .tooLarge) }
    }

    // The fixture is top-left red, top-right green, bottom-left blue,
    // bottom-right yellow. Expected quadrants are hand-derived from the
    // reference's counterclockwise rotation, then horizontal output mirror.
    func testRotationAndOutputMirrorUseOriginalPixelsBeforeCrop() async throws {
        let source = try imageSource(width: 80, height: 40, quadrants: true)
        let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
        defer { try? TelegramUploadVideoCoverIO.discardSelection(selection) }
        let expected = [["red", "green", "blue", "yellow"], ["green", "yellow", "red", "blue"],
                        ["yellow", "blue", "green", "red"], ["blue", "red", "yellow", "green"]]
        var transform = TelegramUploadVideoCoverTransform()
        for turn in 0..<4 {
            let cover = try await TelegramUploadVideoCoverIO.stage(selection, crop: CGRect(x: 0, y: 0, width: 1, height: 1), transform: transform)
            defer { try? TelegramUploadVideoCoverIO.discardCover(cover) }
            XCTAssertEqual(cover.width, turn % 2 == 0 ? 80 : 40)
            XCTAssertEqual(cover.height, turn % 2 == 0 ? 40 : 80)
            let preview = try await TelegramUploadVideoCoverIO.preview(cover)
            XCTAssertEqual(try quadrants(preview.image), expected[turn])
            var mirrored = transform
            mirrored.flipHorizontally()
            let flipped = try await TelegramUploadVideoCoverIO.stage(selection, crop: CGRect(x: 0, y: 0, width: 1, height: 1), transform: mirrored)
            defer { try? TelegramUploadVideoCoverIO.discardCover(flipped) }
            let flippedPreview = try await TelegramUploadVideoCoverIO.preview(flipped)
            XCTAssertEqual(try quadrants(flippedPreview.image), [expected[turn][1], expected[turn][0], expected[turn][3], expected[turn][2]])
            transform.rotate()
        }
        XCTAssertEqual(transform, TelegramUploadVideoCoverTransform())
        transform.rotate(); transform.flipHorizontally()
        let cropped = try await TelegramUploadVideoCoverIO.stage(selection, crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), transform: transform)
        defer { try? TelegramUploadVideoCoverIO.discardCover(cropped) }
        XCTAssertEqual(cropped.width, 20); XCTAssertEqual(cropped.height, 40)
        let croppedPreview = try await TelegramUploadVideoCoverIO.preview(cropped)
        XCTAssertEqual(try quadrants(croppedPreview.image), ["yellow", "yellow", "yellow", "yellow"])
    }

    func testRotateAndFlipCarryCropThroughTransformedImageCoordinates() throws {
        var crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 1200, height: 600), videoSize: CGSize(width: 16, height: 9))
        crop.move(by: CGSize(width: -0.125, height: -0.0625))
        let original = crop
        crop.rotate()
        XCTAssertEqual(crop.rect, CGRect(x: 0.15625, y: 0.375, width: 0.5625, height: 0.5))
        crop.flipHorizontally()
        XCTAssertEqual(crop.rect, CGRect(x: 0.28125, y: 0.375, width: 0.5625, height: 0.5))
        var flipFirst = original
        flipFirst.flipHorizontally(); flipFirst.rotate()
        XCTAssertEqual(flipFirst.transform, crop.transform)
        XCTAssertEqual(flipFirst.rect, CGRect(x: 0.15625, y: 0.125, width: 0.5625, height: 0.5))
        crop.flipHorizontally(); crop.rotate(); crop.rotate(); crop.rotate()
        XCTAssertEqual(crop, original)
        crop.rotate()
        crop.resize(by: CGSize(width: -0.1, height: 0), corner: .bottomRight)
        XCTAssertEqual(crop.rect.width * 600 / (crop.rect.height * 1200), 16.0 / 9, accuracy: 0.000001)
        XCTAssertGreaterThanOrEqual(crop.rect.minX, 0); XCTAssertGreaterThanOrEqual(crop.rect.minY, 0)
        XCTAssertLessThanOrEqual(crop.rect.maxX, 1); XCTAssertLessThanOrEqual(crop.rect.maxY, 1)
    }

    // Source-pixel x/y/width/height are independently rounded. Expanding with
    // floor(origin)/ceil(max) includes pixels outside the selected quadrant.
    func testFractionalCropRoundsOriginAndSizeIndependentlyAcrossOrientations() async throws {
        let source = try imageSource(width: 80, height: 40, quadrants: true)
        let original = try Data(contentsOf: source)
        let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
        defer { try? TelegramUploadVideoCoverIO.discardSelection(selection) }
        let expected = [["yellow", "blue"], ["blue", "red"], ["red", "green"], ["green", "yellow"]]
        var transform = TelegramUploadVideoCoverTransform()
        for turn in 0..<4 {
            for mirror in 0..<2 {
                var state = transform
                if mirror == 1 { state.flipHorizontally() }
                // 80x40 -> (40,20,10,5); 40x80 -> (20,40,5,10).
                let cover = try await TelegramUploadVideoCoverIO.stage(selection,
                    crop: CGRect(x: 0.496, y: 0.496, width: 0.128, height: 0.128), transform: state)
                defer { try? TelegramUploadVideoCoverIO.discardCover(cover) }
                XCTAssertEqual(cover.width, turn % 2 == 0 ? 10 : 5)
                XCTAssertEqual(cover.height, turn % 2 == 0 ? 5 : 10)
                let preview = try await TelegramUploadVideoCoverIO.preview(cover)
                let first = try XCTUnwrap(preview.image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
                XCTAssertEqual(try quadrants(first), Array(repeating: expected[turn][mirror], count: 4))
            }
            transform.rotate()
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    // A positive normalized rectangle can round to an empty source-pixel axis;
    // it must fail rather than silently expanding to a different one-pixel crop.
    func testCropRoundingToZeroPixelAxisFailsAndPreservesSource() async throws {
        let source = try imageSource(width: 80, height: 40)
        let original = try Data(contentsOf: source)
        for size in [CGSize(width: 0.004, height: 0.2), CGSize(width: 0.2, height: 0.004)] {
            do {
                let cover = try await TelegramUploadVideoCoverIO.stage(source,
                    crop: CGRect(origin: CGPoint(x: 0.1, y: 0.1), size: size))
                defer { try? TelegramUploadVideoCoverIO.discardCover(cover) }
                XCTFail("Empty rounded pixel axis was expanded")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidImage) }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    // Independent half-pixel rounding can put the right/bottom edge one pixel
    // beyond the image. CoreGraphics crops to the intersection, without a
    // transparent extra edge in the exported JPEG.
    func testRoundedEdgeCropUsesSourceImageIntersection() async throws {
        let source = try imageSource(width: 82, height: 42)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let reference = try XCTUnwrap(image.cropping(to: CGRect(x: 21, y: 11, width: 62, height: 32)))
        XCTAssertEqual(reference.width, 61); XCTAssertEqual(reference.height, 31)
        let cover = try await TelegramUploadVideoCoverIO.stage(source,
            crop: CGRect(x: 0.25, y: 0.25, width: 0.75, height: 0.75))
        defer { try? TelegramUploadVideoCoverIO.discardCover(cover) }
        XCTAssertEqual(cover.width, 61); XCTAssertEqual(cover.height, 31)
        let preview = try await TelegramUploadVideoCoverIO.preview(cover)
        XCTAssertEqual(try quadrants(preview.image), ["red", "red", "red", "red"])
    }

    private func imageSource(width: Int, height: Int, orientation: Int = 1, quadrants: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Synthetic original.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if quadrants {
            // CGContext coordinates point up; CGImage/preview coordinates start
            // at the top. The three non-red quadrants establish both axes.
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2))
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func quadrants(_ image: CGImage) throws -> [String] {
        try [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { x, y in
            let pixelImage = try XCTUnwrap(image.cropping(to: CGRect(x: Int(Double(image.width) * x), y: Int(Double(image.height) * y), width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            if pixel[0] > 200, pixel[1] > 200, pixel[2] < 100 { return "yellow" }
            if pixel[0] > 200, pixel[1] < 100, pixel[2] < 100 { return "red" }
            if pixel[0] < 100, pixel[1] > 200, pixel[2] < 100 { return "green" }
            if pixel[0] < 100, pixel[1] < 100, pixel[2] > 200 { return "blue" }
            return "unexpected \(pixel)"
        }
    }
}

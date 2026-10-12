import XCTest
import ImageIO
import CoreGraphics
import CryptoKit
@testable import MakoshTelegram

@MainActor
final class TelegramUploadVideoCoverIOTests: XCTestCase {
    private func source(orientation: Int = 1) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Synthetic cover.jpeg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 600,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 300, y: 0, width: 300, height: 600))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "SYNTHETIC_COVER_METADATA"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.0]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // Catches using the full image, ordinary 2560px photo preparation, carrying
    // picker metadata, or binding a digest to different cover bytes.
    func testCroppedCoverUsesOrientedPixelsBoundedJPEGWithoutSourceMetadata() async throws {
        let source = try source(), original = try Data(contentsOf: source)
        let cover = try await TelegramUploadVideoCoverIO.stage(source, crop: CGRect(x: 0.25, y: 0, width: 0.25, height: 1))
        defer { try? TelegramUploadFileIO.discard(cover.imageFile) }
        try TelegramUploadFileIO.validateOwnedStage(cover.imageFile)
        let bytes = try Data(contentsOf: cover.imageFile.url)
        XCTAssertEqual(cover.width, 160); XCTAssertEqual(cover.height, 320)
        XCTAssertEqual(cover.size, Int64(bytes.count))
        XCTAssertEqual(cover.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(decoded) as String?, "public.jpeg")
        XCTAssertEqual(CGImageSourceGetCount(decoded), 1)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
        XCTAssertTrue(properties[kCGImagePropertyOrientation] == nil || (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1)
        let preview = try await TelegramUploadVideoCoverIO.preview(cover)
        XCTAssertEqual(preview.image.width, 160); XCTAssertEqual(preview.image.height, 320)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let sampled = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            sampled.draw(preview.image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(Int(pixel[1]), Int(pixel[0]) + 100, "Crop must select the green stripe")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testEXIFOrientationAppliesBeforeNormalizedCrop() async throws {
        let url = try source(orientation: 6)
        let cover = try await TelegramUploadVideoCoverIO.stage(url, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(cover.imageFile) }
        XCTAssertEqual(cover.width, 160); XCTAssertEqual(cover.height, 320)
        let preview = try await TelegramUploadVideoCoverIO.preview(cover)
        XCTAssertEqual(preview.image.width, 160); XCTAssertEqual(preview.image.height, 320)
    }

    func testInvalidCropAndForeignSourcesCannotCreateCover() async throws {
        let url = try source()
        let crops = [CGRect.zero, CGRect(x: -0.01, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: 1.01, height: 1), CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1),
            CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1)]
        for crop in crops {
            do {
                let unexpected = try await TelegramUploadVideoCoverIO.stage(url, crop: crop)
                try TelegramUploadFileIO.discard(unexpected.imageFile); XCTFail("Invalid crop admitted")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidImage) }
        }
        let link = url.deletingLastPathComponent().appendingPathComponent("alias.jpeg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        for source in [link, url.deletingLastPathComponent()] {
            do {
                let unexpected = try await TelegramUploadVideoCoverIO.stage(source, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
                try TelegramUploadFileIO.discard(unexpected.imageFile); XCTFail("Foreign source admitted")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        }
    }

    // Catches previewing a replacement that still decodes and has the exact
    // admitted size, without binding it to the originally prepared JPEG.
    func testPreviewRejectsSameSizeValidJPEGReplacementAndChangedGeometry() async throws {
        let cover = try await TelegramUploadVideoCoverIO.stage(try source(), crop: CGRect(x: 0.25, y: 0, width: 0.25, height: 1))
        defer { try? TelegramUploadFileIO.discard(cover.imageFile) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 320, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 320))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImageDestinationLossyCompressionQuality: 0.1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertLessThanOrEqual(encoded.length, Int(cover.size), "Replacement must fit the independent fixture")
        var replacement = encoded as Data
        replacement.append(Data(repeating: 0, count: max(0, Int(cover.size) - replacement.count)))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(replacement as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        try replacement.write(to: cover.url)
        XCTAssertEqual(Int64(replacement.count), cover.size)
        do {
            _ = try await TelegramUploadVideoCoverIO.preview(cover)
            XCTFail("Different valid JPEG must not be previewed as the admitted cover")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }

        let wrongGeometry = TelegramUploadVideoCover(id: cover.id, width: 159, height: 320, size: cover.size,
            name: cover.name, url: cover.url, directory: cover.directory,
            sha256: SHA256.hash(data: replacement).map { String(format: "%02x", $0) }.joined())
        do {
            _ = try await TelegramUploadVideoCoverIO.preview(wrongGeometry)
            XCTFail("Cover geometry must describe the actual decoded bytes")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidImage) }
    }

    func testDiscardVideoAlsoReleasesItsSeparateOwnedCover() async throws {
        let image = try source(), videoURL = image.deletingLastPathComponent().appendingPathComponent("synthetic.mov")
        try await writeUploadVideoFixture(videoURL)
        let original = try await TelegramUploadFileIO.stage(videoURL, mode: .video)
        let cover = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(original); try? TelegramUploadFileIO.discard(cover.imageFile) }
        let file = TelegramUploadFile(id: original.id, name: original.name, size: original.size, mode: .video,
            pixelWidth: original.pixelWidth, pixelHeight: original.pixelHeight, url: original.url, directory: original.directory,
            video: original.video, videoCover: cover)
        try TelegramUploadFileIO.discard(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.directory.path))
        try TelegramUploadFileIO.discard(file) // Repeated lifecycle teardown remains harmless.
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path))
    }
}

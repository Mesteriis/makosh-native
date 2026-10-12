import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MakoshTelegram

final class TelegramUploadWebPPreviewIOTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func stage(_ bytes: Data, width: Int32 = 320, height: Int32 = 160,
                       typed: Bool = true) async throws -> TelegramUploadFile {
        let source = try directory().appendingPathComponent("misleading.bin")
        try bytes.write(to: source)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(raw) }
        try FileManager.default.removeItem(at: source)
        return TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory,
            metadata: typed ? .webP(.init(width: width, height: height)) : nil)
    }

    private func jpeg(_ preview: TelegramUploadVideoThumbnail) throws -> CGImage {
        XCTAssertGreaterThan(preview.data.count, 0)
        XCTAssertLessThanOrEqual(preview.data.count, 1_048_576)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(preview.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(Int32(image.width), preview.width)
        XCTAssertEqual(Int32(image.height), preview.height)
        XCTAssertGreaterThan(image.width, 0); XCTAssertGreaterThan(image.height, 0)
        XCTAssertLessThanOrEqual(image.width, 320); XCTAssertLessThanOrEqual(image.height, 320)
        return image
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let start = (y * image.width + x) * 4
        return pixels[start..<start + 3].map(Int.init)
    }

    private func assertQuadrants(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) throws {
        for (x, y, want) in [(40, 20, [255, 0, 0]), (280, 20, [0, 255, 0]),
                             (40, 140, [0, 0, 255]), (280, 140, [255, 255, 0])] {
            let actual = try rgb(image, x: x, y: y)
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(actual[channel] - want[channel]), 20, file: file, line: line)
            }
        }
    }

    // Catches nil placeholder, wrong maximum, wrong codec, missing first-frame colors and raw rewriting.
    func testLargeOwnedWebPProducesBoundedJPEGAndLeavesOriginalUnchanged() async throws {
        let raw = try await stage(uploadWebPLargePreviewFixture, width: 640, height: 320)
        let result = try await TelegramUploadWebPIO.thumbnail(raw)
        let preview = try XCTUnwrap(result)
        XCTAssertEqual(preview.width, 320); XCTAssertEqual(preview.height, 160)
        try assertQuadrants(jpeg(preview))
        XCTAssertEqual(try Data(contentsOf: raw.url), uploadWebPLargePreviewFixture)
        XCTAssertEqual(raw.metadata, .webP(.init(width: 640, height: 320)))
    }

    // DQT is observable codec quality: changing production0.7 to the video's0.3 must fail.
    // The independent ImageIO oracle uses the literal contract quality, not the production helper.
    func testJPEGUsesReferenceQualityPointSeven() async throws {
        let raw = try await stage(uploadWebPLargePreviewFixture, width: 640, height: 320)
        let result = try await TelegramUploadWebPIO.thumbnail(raw)
        let preview = try XCTUnwrap(result)
        _ = try jpeg(preview)
        // JPEG decoding changes the native image representation and its adaptive quantization.
        // The quality oracle therefore starts from the literal original fixture, independently.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(uploadWebPLargePreviewFixture as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true,
             kCGImageSourceCreateThumbnailWithTransform: true,
             kCGImageSourceThumbnailMaxPixelSize: 320,
             kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        let expected = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(expected, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let actualTables = try quantizationTables(preview.data)
        XCTAssertFalse(actualTables.isEmpty)
        XCTAssertEqual(actualTables, try quantizationTables(expected as Data))
    }

    // A cyan second animation frame cannot stand in for the red/green/blue/yellow first canvas.
    func testAnimatedWebPUsesFirstFrameAndRetainsAnimationBytes() async throws {
        let bytes = UploadWebPFixture.animated.data, raw = try await stage(bytes)
        let result = try await TelegramUploadWebPIO.thumbnail(raw)
        let preview = try XCTUnwrap(result)
        XCTAssertEqual(preview.width, 320); XCTAssertEqual(preview.height, 160)
        try assertQuadrants(jpeg(preview))
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    // Frame0 is20x10 at(100,60), but transport JPEG must retain the full320x160 canvas.
    func testPartialFirstFrameUsesCanvasRatherThanPatchOrSecondFrame() async throws {
        let bytes = UploadWebPFixture.partialCanvas.data, raw = try await stage(bytes)
        let result = try await TelegramUploadWebPIO.thumbnail(raw)
        let preview = try XCTUnwrap(result), image = try jpeg(preview)
        XCTAssertEqual(preview.width, 320); XCTAssertEqual(preview.height, 160)
        let inside = try rgb(image, x: 108, y: 64), outside = try rgb(image, x: 20, y: 20)
        XCTAssertGreaterThan(inside[0], 180); XCTAssertLessThan(inside[1], 80); XCTAssertLessThan(inside[2], 80)
        // Transparent background may be flattened by native JPEG to black or white; it is neutral.
        XCTAssertLessThanOrEqual(try XCTUnwrap(outside.max()) - XCTUnwrap(outside.min()), 10)
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    // A safe small sticker must not acquire a synthetic320px canvas.
    func testSmallWebPUsesIntrinsicSizeWithoutUpscaling() async throws {
        let raw = try await stage(UploadWebPFixture.small.data, width: 20, height: 10)
        let result = try await TelegramUploadWebPIO.thumbnail(raw)
        let preview = try XCTUnwrap(result)
        XCTAssertEqual(preview.width, 20); XCTAssertEqual(preview.height, 10)
        _ = try jpeg(preview)
    }

    // Generic documents have no promised native derivative, even when recognizable WebP bytes.
    func testUntypedGenericFileReturnsNilWithoutChangingBytes() async throws {
        for bytes in [Data("owned generic document".utf8), UploadWebPFixture.staticLossless.data] {
            let raw = try await stage(bytes, typed: false)
            let result = try await TelegramUploadWebPIO.thumbnail(raw)
            XCTAssertNil(result)
            XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
        }
    }

    // A derivative must not bless a persisted descriptor that disagrees with the frozen content.
    func testForgedFrozenDimensionsAreRefused() async throws {
        let raw = try await stage(UploadWebPFixture.staticLossless.data, width: 319, height: 160)
        do { _ = try await TelegramUploadWebPIO.thumbnail(raw); XCTFail("Forged descriptor must throw") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidWebP) }
    }

    // Correct digest admits the same held bytes; the transport derivative must not replace them.
    func testMatchingExpectedDigestProducesJPEGAndRetainsOriginal() async throws {
        let raw = try await stage(uploadWebPLargePreviewFixture, width: 640, height: 320)
        let result = try await TelegramUploadWebPIO.thumbnail(raw,
            expectedPlaintextSHA256: "4d6a33066e5a2f0299a8b7d1e297393bcd7a666db3c51630a4838b428a7f47f6")
        let preview = try XCTUnwrap(result)
        XCTAssertEqual(preview.width, 320); XCTAssertEqual(preview.height, 160)
        _ = try jpeg(preview)
        XCTAssertEqual(try Data(contentsOf: raw.url), uploadWebPLargePreviewFixture)
    }

    // Both sources are320x160: metadata equality cannot substitute for exact frozen-byte binding.
    func testWrongOrMalformedExpectedDigestIsRefusedBeforeOptionalCodecFallback() async throws {
        let raw = try await stage(UploadWebPFixture.staticLossy.data)
        for expected in ["928519afa0cfc7456bfd64e1abce36b99043b6bbbbe62bdc5f4dbf81c98b146c",
                         String(repeating: "0", count: 64), "not-a-sha256"] {
            do {
                _ = try await TelegramUploadWebPIO.thumbnail(raw, expectedPlaintextSHA256: expected)
                XCTFail("Wrong exact bytes or malformed digest must throw")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        }
        XCTAssertEqual(try Data(contentsOf: raw.url), UploadWebPFixture.staticLossy.data)
    }

    // Optional codec failure cannot swallow recognizable malformed or unsafe source admission.
    func testMalformedAndUnsafeTypedWebPAreRefused() async throws {
        for bytes in [UploadWebPFixture.staticLossless.data + Data([0]), UploadWebPFixture.overAxis.data,
                      try uploadWebPAnimationFixture(frameCount: 257)] {
            let raw = try await stage(bytes)
            do { _ = try await TelegramUploadWebPIO.thumbnail(raw); XCTFail("Unsafe source must throw") }
            catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidWebP) }
        }
    }

    // A matching filename and metadata must never authorize an arbitrary path or non-file mode.
    func testNonOwnedAndWrongModeTypedStagesAreRefused() async throws {
        let source = try directory().appendingPathComponent("outside.webp")
        try writeUploadWebPFixture(source)
        let outside = TelegramUploadFile(id: UUID(), name: "outside.webp", size: 92, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: source, directory: source.deletingLastPathComponent(),
            metadata: .webP(.init(width: 320, height: 160)))
        do { _ = try await TelegramUploadWebPIO.thumbnail(outside); XCTFail("Arbitrary source must throw") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        let raw = try await stage(UploadWebPFixture.staticLossless.data)
        let wrongMode = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .photo,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory, metadata: raw.metadata)
        do { _ = try await TelegramUploadWebPIO.thumbnail(wrongMode); XCTFail("Wrong mode must throw") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }

    // Size mismatch and symlink replacement are ownership failures, never optional nil previews.
    func testChangedSizeAndReplacedSymlinkAreRefused() async throws {
        let changed = try await stage(UploadWebPFixture.staticLossless.data)
        try (UploadWebPFixture.staticLossless.data + Data([0])).write(to: changed.url)
        do { _ = try await TelegramUploadWebPIO.thumbnail(changed); XCTFail("Stale size must throw") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        let linked = try await stage(UploadWebPFixture.staticLossless.data)
        let source = try directory().appendingPathComponent("outside.webp")
        try writeUploadWebPFixture(source)
        try FileManager.default.removeItem(at: linked.url)
        try FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: source)
        do { _ = try await TelegramUploadWebPIO.thumbnail(linked); XCTFail("Symlink must throw") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertEqual(try Data(contentsOf: source), UploadWebPFixture.staticLossless.data)
    }

    // Cancellation is control flow even though native encoding is optional.
    func testCancellationPropagatesInsteadOfReturningNil() async throws {
        let raw = try await stage(UploadWebPFixture.staticLossless.data)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramUploadWebPIO.thumbnail(raw)
        }
        do { _ = try await task.value; XCTFail("Canceled preview must throw") } catch is CancellationError {}
    }

    private func quantizationTables(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        XCTAssertGreaterThan(bytes.count, 4)
        guard bytes.count > 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { throw CocoaError(.fileReadCorruptFile) }
        var position = 2, result: [Data] = []
        while position + 1 < bytes.count {
            guard bytes[position] == 0xff else { throw CocoaError(.fileReadCorruptFile) }
            while position < bytes.count && bytes[position] == 0xff { position += 1 }
            guard position < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            let marker = bytes[position]; position += 1
            if marker == 0xda || marker == 0xd9 { break }
            guard position + 1 < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            let length = Int(bytes[position]) * 256 + Int(bytes[position + 1])
            guard length >= 2, position + length <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            if marker == 0xdb { result.append(Data(bytes[position + 2..<position + length])) }
            position += length
        }
        return result
    }
}

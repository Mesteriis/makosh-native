import XCTest
import Foundation
import ImageIO
import CryptoKit
import Darwin
import UniformTypeIdentifiers
@testable import MakoshTelegram

@MainActor
final class TelegramUploadGIFPreviewIOTests: XCTestCase {
    private func stage(_ bytes: Data, width: Int32 = 32, height: Int32 = 16,
                       delays: [Float] = [0.05, 0.2, 0.4]) async throws -> TelegramUploadFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("opaque.bin")
        try bytes.write(to: source)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(raw) }
        try FileManager.default.removeItem(at: source)
        return bound(raw, .init(width: width, height: height, frameDurations: delays, sourceSHA256: digest(bytes)))
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func bound(_ raw: TelegramUploadFile, _ facts: TelegramUploadGIFMetadata) -> TelegramUploadFile {
        .init(id: raw.id, name: raw.name, size: raw.size, mode: .file, pixelWidth: nil, pixelHeight: nil,
            url: raw.url, directory: raw.directory, metadata: .gif(facts))
    }

    private func jpeg(_ preview: TelegramUploadVideoThumbnail) throws -> CGImage {
        XCTAssertGreaterThan(preview.data.count, 0)
        XCTAssertLessThanOrEqual(preview.data.count, 1_048_576)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(preview.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Int(preview.width)); XCTAssertEqual(image.height, Int(preview.height))
        return image
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard image.width > 0, image.height > 0, image.width <= 320, image.height <= 320,
              x >= 0, x < image.width, y >= 0, y < image.height else {
            XCTFail("JPEG pixel read requires a bounded image and a point inside its dimensions")
            throw TelegramUploadGIFError.invalidGIF
        }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<(offset + 3)])
    }

    // Encode the original first-frame image, not the lossy returned JPEG: avoids a circular quality oracle.
    private func qualityPointSevenJPEG(_ bytes: Data) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try XCTUnwrap((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceThumbnailMaxPixelSize: min(320, max(width, height)),
             kCGImageSourceCreateThumbnailFromImageAlways: true,
             kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func quantizationTables(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xff, 0xd8])
        var offset = 2, tables = Data()
        while offset + 3 < bytes.count {
            XCTAssertEqual(bytes[offset], 0xff)
            let marker = bytes[offset + 1]
            if marker == 0xda || marker == 0xd9 { break }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else {
                XCTFail("Invalid JPEG segment length"); return Data()
            }
            if marker == 0xdb { tables.append(contentsOf: bytes[(offset + 4)..<(offset + 2 + length)]) }
            offset += 2 + length
        }
        XCTAssertFalse(tables.isEmpty)
        return tables
    }

    // Catches MP4/last-frame/0.3 reuse, upscaling and rewriting the original GIF.
    func testSmallGIFUsesFirstFrameJPEGPointSevenWithoutUpscaling() async throws {
        let raw = try await stage(uploadGIFTimingFixture)
        let result = try await TelegramUploadGIFIO.thumbnail(raw)
        let preview = try XCTUnwrap(result)
        XCTAssertEqual(preview.width, 32); XCTAssertEqual(preview.height, 16)
        let rgb = try pixel(jpeg(preview), x: 16, y: 8)
        XCTAssertGreaterThan(rgb[0], 240); XCTAssertLessThan(rgb[1], 20); XCTAssertLessThan(rgb[2], 20)
        XCTAssertEqual(try quantizationTables(preview.data), try quantizationTables(qualityPointSevenJPEG(uploadGIFTimingFixture)))
        XCTAssertEqual(try Data(contentsOf: raw.url), uploadGIFTimingFixture)
    }

    // Catches omitting the 320px cap or distorting the original canvas aspect.
    func testLargeGIFIsFittedTo320By160() async throws {
        let bytes = uploadGIFFixture([.init(color: 1, delay: 5, width: 640, height: 320)], width: 640, height: 320)
        let raw = try await stage(bytes, width: 640, height: 320, delays: [0.05])
        let result = try await TelegramUploadGIFIO.thumbnail(raw)
        let preview = try XCTUnwrap(result)
        XCTAssertEqual(preview.width, 320); XCTAssertEqual(preview.height, 160)
        _ = try jpeg(preview)
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    // Catches stretching a first-frame patch to the full GIF canvas.
    func testPartialFirstFrameKeepsCanvasAndPlacement() async throws {
        let bytes = uploadGIFFixture([.init(color: 1, delay: 5, x: 8, y: 4, width: 8, height: 8),
            .init(color: 2, delay: 20)])
        let raw = try await stage(bytes, delays: [0.05, 0.2])
        let result = try await TelegramUploadGIFIO.thumbnail(raw)
        let preview = try XCTUnwrap(result)
        XCTAssertEqual(preview.width, 32); XCTAssertEqual(preview.height, 16)
        let image = try jpeg(preview)
        let red = try pixel(image, x: 12, y: 8), background = try pixel(image, x: 1, y: 1)
        XCTAssertGreaterThan(red[0], 180); XCTAssertLessThan(red[1], 50); XCTAssertLessThan(red[2], 50)
        XCTAssertTrue(background.allSatisfy { $0 < 50 })
    }

    // Catches trusting geometry/timing or a second read instead of the frozen original-byte digest.
    func testWrongHashAndSameFactsByteMutationAreRejected() async throws {
        let raw = try await stage(uploadGIFTimingFixture)
        let wrong = bound(raw, .init(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.4],
            sourceSHA256: String(repeating: "0", count: 64)))
        do { _ = try await TelegramUploadGIFIO.thumbnail(wrong); XCTFail("Wrong frozen source hash must throw") }
        catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
        var changed = uploadGIFTimingFixture; changed[16] = 254
        XCTAssertEqual(changed.count, uploadGIFTimingFixture.count)
        try changed.write(to: raw.url)
        do { _ = try await TelegramUploadGIFIO.thumbnail(raw); XCTFail("Equal GIF facts must not authorize changed bytes") }
        catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
        XCTAssertEqual(try Data(contentsOf: raw.url), changed)
    }

    // Catches ignoring frozen facts or bypassing the existing owned path/permission boundary.
    func testFrozenFactsAndOwnershipMismatchAreRejected() async throws {
        let raw = try await stage(uploadGIFTimingFixture)
        let wrong = bound(raw, .init(width: 64, height: 16, frameDurations: [0.05, 0.2, 0.4],
            sourceSHA256: digest(uploadGIFTimingFixture)))
        do { _ = try await TelegramUploadGIFIO.thumbnail(wrong); XCTFail("Forged frozen GIF facts must throw") }
        catch { XCTAssertEqual(error as? TelegramUploadGIFError, .invalidGIF) }
        let foreign = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.directory, directory: raw.directory, metadata: raw.metadata)
        do { _ = try await TelegramUploadGIFIO.thumbnail(foreign); XCTFail("Foreign path must throw") }
        catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
        XCTAssertEqual(chmod(raw.url.path, 0o644), 0)
        defer { _ = chmod(raw.url.path, 0o600) }
        do { _ = try await TelegramUploadGIFIO.thumbnail(raw); XCTFail("Relaxed owned permissions must throw") }
        catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
    }

    // Catches swallowing cancellation or treating a non-GIF/generic file as optional codec failure.
    func testCancelledAndNonGIFInputsAreRefused() async throws {
        let raw = try await stage(uploadGIFTimingFixture)
        let task = Task { try await TelegramUploadGIFIO.thumbnail(raw) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Already cancelled preview must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let generic = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory)
        do { _ = try await TelegramUploadGIFIO.thumbnail(generic); XCTFail("Missing frozen GIF metadata must throw") }
        catch { XCTAssertEqual(error as? TelegramUploadGIFError, .invalidGIF) }
        let notGIF = try await stage(Data("synthetic text".utf8), delays: [0.05])
        do { _ = try await TelegramUploadGIFIO.thumbnail(notGIF); XCTFail("Typed GIF claim over non-GIF bytes must throw") }
        catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
    }
}

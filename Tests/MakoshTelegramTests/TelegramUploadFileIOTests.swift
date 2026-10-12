import XCTest
import Foundation
import Darwin
import ImageIO
import CoreGraphics
import CryptoKit
@testable import MakoshTelegram

final class TelegramUploadFileIOTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func assertStageError(_ expected: TelegramUploadFileError, source: URL, mode: TelegramUploadMode) async {
        do {
            let file = try await TelegramUploadFileIO.stage(source, mode: mode)
            try TelegramUploadFileIO.discard(file)
            XCTFail("Expected stage rejection")
        } catch let error as TelegramUploadFileError {
            XCTAssertEqual(error, expected)
        } catch { XCTFail("Unexpected staging error type") }
    }

    private func image(at url: URL, width: Int = 60, height: Int = 30, orientation: Int = 6) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let metadata: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "synthetic private comment"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.34, kCGImagePropertyGPSLatitudeRef: "N"]]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testDocumentPreservesBytesAndSourceWithPrivateOwnedStageAndIdempotentCleanup() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("synthetic.bin")
        let bytes = Data(repeating: 0xa5, count: 2 * 1024 * 1024 + 19)
        try bytes.write(to: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        defer { try? TelegramUploadFileIO.discard(file) }
        XCTAssertEqual(file.size, Int64(bytes.count))
        XCTAssertEqual(file.mode, .file)
        XCTAssertNil(file.pixelWidth); XCTAssertNil(file.pixelHeight)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertNotEqual(file.url, source)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: file.directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.directory.path), [file.url.lastPathComponent])
        try TelegramUploadFileIO.discard(file)
        try TelegramUploadFileIO.discard(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testEmptyDocumentIsValidButEmptyPhotoIsNot() async throws {
        let source = try directory().appendingPathComponent("empty")
        try Data().write(to: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        defer { try? TelegramUploadFileIO.discard(file) }
        XCTAssertEqual(file.size, 0)
        await assertStageError(.invalidImage, source: source, mode: .photo)
    }

    func testSpecialInputsAreRejectedWithoutReadingTheirContents() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("source")
        try Data([1, 2]).write(to: source)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        for input in [root, link, fifo, root.appendingPathComponent("missing")] {
            await assertStageError(.unavailable, source: input, mode: .file)
        }
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2]))
    }

    func testSparseDocumentAndPhotoByteCapsRejectWithoutLargeRead() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("sparse")
        let fd = Darwin.open(source.path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        XCTAssertEqual(ftruncate(fd, off_t(4 * 1024 * 1024 * 1024 + 1)), 0)
        await assertStageError(.tooLarge, source: source, mode: .file)
        XCTAssertEqual(ftruncate(fd, off_t(20 * 1024 * 1024 + 1)), 0)
        await assertStageError(.tooLarge, source: source, mode: .photo)
    }

    func testPhotoNormalizesOrientationStripsMetadataAndPreservesOriginal() async throws {
        let source = try directory().appendingPathComponent("original.jpg")
        try image(at: source)
        let original = try Data(contentsOf: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .photo)
        defer { try? TelegramUploadFileIO.discard(file) }
        XCTAssertEqual(file.mode, .photo)
        XCTAssertEqual(file.pixelWidth, 30)
        XCTAssertEqual(file.pixelHeight, 60)
        XCTAssertTrue(file.name.hasSuffix(".jpg"))
        let result = try XCTUnwrap(CGImageSourceCreateWithURL(file.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(result) as String?, "public.jpeg")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, Int(file.pixelWidth!))
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, Int(file.pixelHeight!))
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
        XCTAssertTrue(properties[kCGImagePropertyOrientation] == nil || (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1)
        XCTAssertEqual(file.size, Int64(try Data(contentsOf: file.url).count))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPhotoDownsamplesAndRejectsCorruptionAndPixelBounds() async throws {
        let source = try directory().appendingPathComponent("image.jpg")
        try image(at: source, width: 3000, height: 100, orientation: 1)
        let staged = try await TelegramUploadFileIO.stage(source, mode: .photo)
        defer { try? TelegramUploadFileIO.discard(staged) }
        XCTAssertLessThanOrEqual(max(staged.pixelWidth!, staged.pixelHeight!), 2560)
        try image(at: source, width: 8193, height: 1, orientation: 1)
        await assertStageError(.tooLarge, source: source, mode: .photo)
        try image(at: source, width: 6325, height: 6325, orientation: 1)
        await assertStageError(.tooLarge, source: source, mode: .photo)
        try Data("not an image".utf8).write(to: source)
        await assertStageError(.invalidImage, source: source, mode: .photo)
    }

    // Catches applying the large-photo dimension to a new preparation without an explicit setting.
    func testOrdinaryPhotoDefaultsToReference1280Pixels() async throws {
        let source = try directory().appendingPathComponent("default-photo.jpg")
        try image(at: source, width: 3000, height: 1500, orientation: 1)
        let original = try Data(contentsOf: source)
        let photo = try await TelegramUploadFileIO.stage(source, mode: .photo)
        defer { try? TelegramUploadFileIO.discard(photo) }
        XCTAssertEqual(photo.pixelWidth, 1280)
        XCTAssertEqual(photo.pixelHeight, 640)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    // Catches dropping the explicit large-photo choice or applying it to raw document bytes.
    func testLargePhotoChoiceUses2560AndDoesNotChangeDocuments() async throws {
        let source = try directory().appendingPathComponent("large-photo.jpg")
        try image(at: source, width: 3000, height: 1500, orientation: 1)
        let original = try Data(contentsOf: source)
        let photo = try await TelegramUploadFileIO.stage(source, mode: .photo, photoSize: .large)
        let document = try await TelegramUploadFileIO.stage(source, mode: .file, photoSize: .large)
        defer { try? TelegramUploadFileIO.discard(photo); try? TelegramUploadFileIO.discard(document) }
        XCTAssertEqual(photo.pixelWidth, 2560); XCTAssertEqual(photo.pixelHeight, 1280)
        XCTAssertEqual(try Data(contentsOf: document.url), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    // Catches lowering the restoration bound together with the new-generation default.
    func testPreviouslyPreparedLargePhotoRestoresWithoutTranscoding() async throws {
        let source = try directory().appendingPathComponent("retained-photo.jpg")
        try image(at: source, width: 2560, height: 1280, orientation: 1)
        let original = try Data(contentsOf: source)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        defer { try? TelegramUploadFileIO.discard(raw) }
        let restored = try await TelegramUploadFileIO.restoredStage(id: raw.id, name: raw.name, size: raw.size,
            mode: .photo, url: raw.url, directory: raw.directory)
        XCTAssertEqual(restored.pixelWidth, 2560); XCTAssertEqual(restored.pixelHeight, 1280)
        XCTAssertEqual(try Data(contentsOf: restored.url), original)
    }

    // Catches falling back to sequential ImageIO or changing the primary quality75 quantization.
    func testOrdinaryPhotoUsesProgressiveJPEGAtQuality75() async throws {
        let source = try directory().appendingPathComponent("quality.jpg")
        try image(at: source, orientation: 1)
        // Standard luminance table, quality75 scaling, in JPEG zigzag order.
        let expected = Data([8,6,6,7,6,5,8,7,7,7,9,9,8,10,12,20,13,12,11,11,12,25,
            18,19,15,20,29,26,31,30,29,26,28,28,32,36,46,39,32,34,44,35,28,28,40,
            55,41,44,48,49,52,52,52,31,39,57,61,56,50,60,46,51,52,50])
        for size in [TelegramUploadPhotoSize.standard, .large] {
            let photo = try await TelegramUploadFileIO.stage(source, mode: .photo, photoSize: size)
            defer { try? TelegramUploadFileIO.discard(photo) }
            let bytes = try Data(contentsOf: photo.url)
            XCTAssertEqual(try jpegLuminanceQuantization(bytes), expected)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
            let jfif = try XCTUnwrap(properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any])
            XCTAssertEqual((jfif[kCGImagePropertyJFIFIsProgressive] as? NSNumber)?.boolValue, true)
        }
    }

    // Catches dropping the reference's white compositing background for transparent source pixels.
    func testPhotoCompositesTransparentPixelsOnWhite() async throws {
        let source = try directory().appendingPathComponent("transparent.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 60, bitsPerComponent: 8,
            bytesPerRow: 240, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photo = try await TelegramUploadFileIO.stage(source, mode: .photo)
        defer { try? TelegramUploadFileIO.discard(photo) }
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(photo.url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let pixel = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        pixel.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(pixel.data).assumingMemoryBound(to: UInt8.self)
        for channel in 0..<3 { XCTAssertGreaterThanOrEqual(bytes[channel], 250) }
    }

    private func jpegLuminanceQuantization(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { throw CocoaError(.fileReadCorruptFile) }
        var offset = 2
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xff else { throw CocoaError(.fileReadCorruptFile) }
            let marker = bytes[offset + 1]
            guard marker != 0xda && marker != 0xd9 else { break }
            let length = Int(bytes[offset + 2]) * 256 + Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            if marker == 0xdb {
                var table = offset + 4
                while table < offset + 2 + length {
                    let info = bytes[table], size = (info >> 4 == 0 ? 64 : 128)
                    guard table + 1 + size <= offset + 2 + length else { throw CocoaError(.fileReadCorruptFile) }
                    if info & 0x0f == 0 { return Data(bytes[table + 1..<table + 1 + size]) }
                    table += 1 + size
                }
            }
            offset += 2 + length
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    @MainActor func testAlreadyCancelledStagePreservesOriginalWithoutStartingWorker() async throws {
        let source = try directory().appendingPathComponent("original")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        let operation = Task { @MainActor in
            try await TelegramUploadFileIO.stage(source, mode: .file)
        }
        // The task inherits this actor and cannot begin until this method suspends.
        operation.cancel()
        do {
            let file = try await operation.value
            try TelegramUploadFileIO.discard(file)
            XCTFail("Cancelled stage unexpectedly succeeded")
        } catch is CancellationError {
            // Expected before any staging directory/worker is created.
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testCleanupRefusesPathsOutsideOwnedStage() throws {
        let root = try directory()
        let source = root.appendingPathComponent("keep")
        try Data([7]).write(to: source)
        let forged = TelegramUploadFile(id: UUID(), name: "keep", size: 1, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: source, directory: root)
        XCTAssertThrowsError(try TelegramUploadFileIO.discard(forged)) {
            XCTAssertEqual($0 as? TelegramUploadFileError, .stagingFailed)
        }
        XCTAssertEqual(try Data(contentsOf: source), Data([7]))
    }
    func testOwnedNormalizedPhotoPreviewPreservesSourceAndStageBytes() async throws {
        let source = try directory().appendingPathComponent("preview.jpg")
        try image(at: source)
        let original = try Data(contentsOf: source)
        let staged = try await TelegramUploadFileIO.stage(source, mode: .photo)
        addTeardownBlock { try TelegramUploadFileIO.discard(staged) }
        let bytes = try Data(contentsOf: staged.url)
        let preview = try await TelegramUploadFileIO.preview(staged)
        XCTAssertEqual(preview.image.width, 30); XCTAssertEqual(preview.image.height, 60)
        XCTAssertEqual(preview.originalSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try Data(contentsOf: staged.url), bytes)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let document = TelegramUploadFile(id: staged.id, name: staged.name, size: staged.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: staged.url, directory: staged.directory)
        do { _ = try await TelegramUploadFileIO.preview(document); XCTFail("Documents cannot use photo preview") } catch {}
        let forged = TelegramUploadFile(id: UUID(), name: staged.name, size: staged.size, mode: .photo,
            pixelWidth: staged.pixelWidth, pixelHeight: staged.pixelHeight, url: source, directory: staged.directory)
        do { _ = try await TelegramUploadFileIO.preview(forged); XCTFail("Foreign stage must fail") } catch {}
        try TelegramUploadFileIO.discard(staged)
        do { _ = try await TelegramUploadFileIO.preview(staged); XCTFail("Removed stage must fail") } catch {}
    }

    @MainActor func testCancelledPreviewDoesNotDecodeOrMutateOwnedStage() async throws {
        let source = try directory().appendingPathComponent("preview.jpg")
        try image(at: source)
        let staged = try await TelegramUploadFileIO.stage(source, mode: .photo)
        addTeardownBlock { try TelegramUploadFileIO.discard(staged) }
        let original = try Data(contentsOf: staged.url)
        let task = Task { @MainActor in try await TelegramUploadFileIO.preview(staged) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preview must fail") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation") }
        XCTAssertEqual(try Data(contentsOf: staged.url), original)
    }
}

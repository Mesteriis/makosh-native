import XCTest
import Foundation
import Darwin
import ImageIO
import CoreGraphics
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
}

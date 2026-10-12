import XCTest
import Foundation
import Darwin
import CoreGraphics
import ImageIO
@testable import MakoshTelegram

final class TelegramDownloadedFileIOTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertFailure(_ expected: TelegramFileError, file: StaticString = #filePath,
                               line: UInt = #line, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected a safe file error", file: file, line: line)
        } catch let error as TelegramFileError {
            switch (expected, error) {
            case (.unavailable, .unavailable), (.copyFailed, .copyFailed),
                 (.previewLimit, .previewLimit), (.invalidImage, .invalidImage): break
            default: XCTFail("Unexpected file error category", file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }

    private func assertNoStagingFiles(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix(".makosh-export-") }, file: file, line: line)
    }

    private func png(at url: URL, width: Int, height: Int) throws -> Int64 {
        // Grayscale permits a valid large-pixel fixture without a large encoded file.
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return Int64(try Data(contentsOf: url).count)
    }

    func testAlbumThumbnailDecodesAtMost512PixelsAndPreservesAspect() async throws {
        let file = try directory().appendingPathComponent("large-photo")
        let size = try png(at: file, width: 2048, height: 1024)
        let preview = try await TelegramDownloadedFileIO.thumbnail(source: file, expectedSize: size)
        XCTAssertEqual(preview.image.width, 512)
        XCTAssertEqual(preview.image.height, 256)
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(size))
    }

    func testAtomicCopyAndOverwritePreserveOriginalAndReplaceDestinationInode() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let original = Data("synthetic original bytes".utf8)
        try original.write(to: source)
        try await TelegramDownloadedFileIO.copy(source: source, expectedSize: Int64(original.count), destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        // An alias of the previous destination must retain its old bytes after atomic replacement.
        let old = Data("previous destination".utf8)
        try old.write(to: destination)
        let alias = root.appendingPathComponent("old-destination-alias")
        try FileManager.default.linkItem(at: destination, to: alias)
        try await TelegramDownloadedFileIO.copy(source: source, expectedSize: Int64(original.count), destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: alias), old)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try assertNoStagingFiles(root)
    }

    func testSizeMismatchPreservesDestinationAndLeavesNoStagingFile() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let original = Data([1, 2, 3])
        let existing = Data([8, 9])
        try original.write(to: source)
        try existing.write(to: destination)
        for wrongSize: Int64 in [-1, 2, 4] {
            await assertFailure(.unavailable) {
                try await TelegramDownloadedFileIO.copy(source: source, expectedSize: wrongSize, destination: destination)
            }
            XCTAssertEqual(try Data(contentsOf: destination), existing)
            XCTAssertEqual(try Data(contentsOf: source), original)
            try assertNoStagingFiles(root)
        }
    }

    func testSymlinkDirectoryAndFIFOInputsAreRejectedPromptly() async throws {
        let root = try directory()
        let target = root.appendingPathComponent("target")
        try Data([1]).write(to: target)
        let symlink = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        let destination = root.appendingPathComponent("destination")
        for source in [symlink, root, fifo] {
            let completed = expectation(description: "Reject special source without blocking")
            let operation = Task {
                do {
                    try await TelegramDownloadedFileIO.copy(source: source, expectedSize: 1, destination: destination)
                    XCTFail("Special source unexpectedly copied")
                } catch TelegramFileError.unavailable {
                    // Expected safe rejection.
                } catch {
                    XCTFail("Unexpected special-source error")
                }
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 2)
            operation.cancel()
            // Unblock a regressed blocking FIFO open, so a failed test cannot strand its worker.
            if source == fifo {
                let fd = Darwin.open(fifo.path, O_RDWR | O_NONBLOCK)
                if fd >= 0 { Darwin.close(fd) }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        XCTAssertEqual(try Data(contentsOf: target), Data([1]))
        try assertNoStagingFiles(root)
    }

    func testSameInodeAndHardlinkDestinationAreRejected() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("source")
        let alias = root.appendingPathComponent("alias")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: source)
        try FileManager.default.linkItem(at: source, to: alias)
        for destination in [source, alias] {
            await assertFailure(.copyFailed) {
                try await TelegramDownloadedFileIO.copy(source: source, expectedSize: 4, destination: destination)
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: alias), bytes)
            try assertNoStagingFiles(root)
        }
    }

    func testSpecialDestinationsFailAfterCopyWithoutReplacingOrLeavingTemporaryFiles() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("source")
        try Data([1, 2, 3]).write(to: source)
        let target = root.appendingPathComponent("target")
        try Data([9]).write(to: target)
        let symlink = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        for destination in [symlink, folder, fifo] {
            await assertFailure(.copyFailed) {
                try await TelegramDownloadedFileIO.copy(source: source, expectedSize: 3, destination: destination)
            }
            try assertNoStagingFiles(root)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data([9]))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        var info = stat()
        XCTAssertEqual(Darwin.lstat(fifo.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO)
    }

    func testValidPNGProducesBoundedThumbnailAndLeavesSourceIntact() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("image.png")
        let size = try png(at: source, width: 2000, height: 100)
        let original = try Data(contentsOf: source)
        let preview = try await TelegramDownloadedFileIO.image(source: source, expectedSize: size)
        XCTAssertGreaterThan(preview.image.width, 0)
        XCTAssertGreaterThan(preview.image.height, 0)
        XCTAssertLessThanOrEqual(max(preview.image.width, preview.image.height), 1280)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testEmptyCorruptAndMismatchedImageInputsFailSafely() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("image")
        try Data().write(to: source)
        await assertFailure(.previewLimit) { _ = try await TelegramDownloadedFileIO.image(source: source, expectedSize: 0) }
        let corrupt = Data("synthetic non-image".utf8)
        try corrupt.write(to: source)
        await assertFailure(.invalidImage) {
            _ = try await TelegramDownloadedFileIO.image(source: source, expectedSize: Int64(corrupt.count))
        }
        await assertFailure(.unavailable) {
            _ = try await TelegramDownloadedFileIO.image(source: source, expectedSize: Int64(corrupt.count + 1))
        }
    }

    func testAlreadyCancelledCallerStartsNoFileWork() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await TelegramDownloadedFileIO.copy(source: source, expectedSize: 3, destination: destination)
                XCTFail("Cancelled caller copied a file")
            } catch is CancellationError { }
            catch { XCTFail("Cancellation was not preserved") }
            do {
                _ = try await TelegramDownloadedFileIO.image(source: source, expectedSize: 0)
                XCTFail("Cancelled caller started decoding")
            } catch is CancellationError { }
            catch { XCTFail("Cancellation must precede file/decoder validation") }
        }
        await operation.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        try assertNoStagingFiles(root)
    }

    func testByteAndPixelBoundsRejectBeforeFullDecode() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("image.png")
        // Byte guard runs before source open, so this requires no oversized allocation.
        await assertFailure(.previewLimit) {
            _ = try await TelegramDownloadedFileIO.image(source: source, expectedSize: 20 * 1024 * 1024 + 1)
        }
        let wideSize = try png(at: source, width: 8193, height: 1)
        await assertFailure(.previewLimit) {
            _ = try await TelegramDownloadedFileIO.image(source: source, expectedSize: wideSize)
        }
        let pixelSize = try png(at: source, width: 6325, height: 6325)
        XCTAssertLessThan(pixelSize, 20 * 1024 * 1024)
        await assertFailure(.previewLimit) {
            _ = try await TelegramDownloadedFileIO.image(source: source, expectedSize: pixelSize)
        }
    }
}

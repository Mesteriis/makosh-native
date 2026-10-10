import XCTest
import Foundation
import Darwin
@testable import MakoshTelegram

final class TelegramPlaybackFileIOTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func failure(_ error: TelegramPlaybackFileError, source: URL, size: Int64) async {
        do {
            let file = try await TelegramPlaybackFileIO.prepare(source: source, expectedSize: size)
            try TelegramPlaybackFileIO.discard(file)
            XCTFail("Expected rejection")
        } catch let actual as TelegramPlaybackFileError { XCTAssertEqual(actual, error) }
        catch { XCTFail("Unexpected error category") }
    }

    func testStreamedCopyPreservesSourceAndPrivateModesAndCleanupIsIdempotent() async throws {
        let source = try directory().appendingPathComponent("original")
        let bytes = Data(repeating: 0x7a, count: 2 * 1024 * 1024 + 33)
        try bytes.write(to: source)
        let staged = try await TelegramPlaybackFileIO.prepare(source: source, expectedSize: Int64(bytes.count))
        defer { try? TelegramPlaybackFileIO.discard(staged) }
        XCTAssertEqual(try Data(contentsOf: staged.url), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: staged.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: staged.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staged.directory.path), [staged.url.lastPathComponent])
        try TelegramPlaybackFileIO.discard(staged); try TelegramPlaybackFileIO.discard(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testInvalidSizesAndCapRejectBeforeCopy() async throws {
        let source = try directory().appendingPathComponent("original")
        try Data([1, 2, 3]).write(to: source)
        for size: Int64 in [-1, 0, 2, 4] { await failure(.unavailable, source: source, size: size) }
        await failure(.tooLarge, source: source, size: 4 * 1024 * 1024 * 1024 + 1)
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    func testContainerSuffixUsesBytesInsteadOfSourceName() async throws {
        let root = try directory()
        for (header, suffix) in [("OggSignored", "ogg"), ("RIFFxxxxWAVE", "wav"), ("xxxxftypxxxx", "mp4"), ("not media", "")] {
            let source = root.appendingPathComponent(UUID().uuidString + ".m3u8")
            let data = Data(header.utf8)
            try data.write(to: source)
            let staged = try await TelegramPlaybackFileIO.prepare(source: source, expectedSize: Int64(data.count))
            XCTAssertEqual(staged.url.pathExtension, suffix)
            XCTAssertEqual(try Data(contentsOf: staged.url), data)
            try TelegramPlaybackFileIO.discard(staged)
        }
    }

    func testSpecialPathsAndNonFileURLsRejected() async throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        try Data([1]).write(to: source)
        let link = root.appendingPathComponent("link"), fifo = root.appendingPathComponent("fifo")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for path in [root, link, fifo, root.appendingPathComponent("missing"), URL(string: "https://example.invalid/media")!] {
            await failure(.unavailable, source: path, size: 1)
        }
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
    }

    @MainActor func testPreCancelledPreparationNeverCopies() async throws {
        let source = try directory().appendingPathComponent("source")
        try Data([1]).write(to: source)
        let task = Task { @MainActor in try await TelegramPlaybackFileIO.prepare(source: source, expectedSize: 1) }
        task.cancel()
        do {
            let file = try await task.value
            try TelegramPlaybackFileIO.discard(file)
            XCTFail("Cancelled operation succeeded")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
    }

    func testDiscardRefusesForgedPathsAndSymlinkDirectoryWithoutDeletingTarget() throws {
        let root = try directory(), source = root.appendingPathComponent("keep")
        try Data([9]).write(to: source)
        let id = UUID()
        let forged = TelegramPlaybackFile(id: id, url: source, directory: root)
        XCTAssertThrowsError(try TelegramPlaybackFileIO.discard(forged)) {
            XCTAssertEqual($0 as? TelegramPlaybackFileError, .preparationFailed)
        }
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-playback-" + id.uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: owned) }
        let symlink = TelegramPlaybackFile(id: id, url: owned.appendingPathComponent("payload-" + id.uuidString), directory: owned)
        XCTAssertThrowsError(try TelegramPlaybackFileIO.discard(symlink)) {
            XCTAssertEqual($0 as? TelegramPlaybackFileError, .preparationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: source), Data([9]))
    }

    func testDiscardRefusesRegularFileAtOwnedDirectoryPath() throws {
        let id = UUID()
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-playback-" + id.uuidString, isDirectory: true)
        try Data([7]).write(to: owned)
        defer { try? FileManager.default.removeItem(at: owned) }
        let file = TelegramPlaybackFile(id: id, url: owned.appendingPathComponent("payload-" + id.uuidString), directory: owned)
        XCTAssertThrowsError(try TelegramPlaybackFileIO.discard(file))
        XCTAssertEqual(try Data(contentsOf: owned), Data([7]))
    }
}

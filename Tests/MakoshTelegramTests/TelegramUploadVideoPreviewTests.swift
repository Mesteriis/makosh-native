import XCTest
@testable import MakoshTelegram

@MainActor
final class TelegramUploadVideoPreviewTests: XCTestCase {
    private func source() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("portrait.mov")
    }

    // A photo-only decoder or missing preferred transform would refuse/misorient
    // this actual MOV; unbounded decoding would exceed the reference's320px cap.
    func testVideoPosterHonorsDisplayTransformAndBoundsWithoutChangingOriginalBytes() async throws {
        let url = try source()
        try await writeUploadVideoFixture(url, rotated: true, width: 640, height: 320)
        let original = try Data(contentsOf: url)
        let file = try await TelegramUploadFileIO.stage(url, mode: .video)
        defer { try? TelegramUploadFileIO.discard(file) }
        let preview = try await TelegramUploadFileIO.preview(file)
        XCTAssertEqual(preview.image.width, 160)
        XCTAssertEqual(preview.image.height, 320)
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testVideoPosterRefusesMissingDescriptorForeignAndRemovedStage() async throws {
        let url = try source()
        try await writeUploadVideoFixture(url)
        let file = try await TelegramUploadFileIO.stage(url, mode: .video)
        defer { try? TelegramUploadFileIO.discard(file) }
        let missing = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .video,
            pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: file.url, directory: file.directory)
        let foreign = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .video,
            pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: url, directory: file.directory, video: file.video)
        for invalid in [missing, foreign] {
            do { _ = try await TelegramUploadFileIO.preview(invalid); XCTFail("Expected invalid video stage rejection") }
            catch is TelegramUploadFileError {}
        }
        try TelegramUploadFileIO.discard(file)
        do { _ = try await TelegramUploadFileIO.preview(file); XCTFail("A removed stage cannot be decoded") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAlreadyCancelledVideoPosterDoesNotConsumeStage() async throws {
        let url = try source()
        try await writeUploadVideoFixture(url)
        let file = try await TelegramUploadFileIO.stage(url, mode: .video)
        defer { try? TelegramUploadFileIO.discard(file) }
        let task = Task { try await TelegramUploadFileIO.preview(file) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }
}

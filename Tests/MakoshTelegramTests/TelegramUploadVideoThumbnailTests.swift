import XCTest
import ImageIO
@testable import MakoshTelegram

@MainActor
final class TelegramUploadVideoThumbnailTests: XCTestCase {
    // Missing JPEG encoding or ignored preferred transform breaks the actual
    // thumbnail bytes consumed by MediaBox, rather than just a DTO assertion.
    func testFirstFrameThumbnailIsBoundedOrientedJPEGAndPreservesVideoBytes() async throws {
        let source = try source()
        try await writeUploadVideoFixture(source, rotated: true, width: 640, height: 320)
        let original = try Data(contentsOf: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .video)
        defer { try? TelegramUploadFileIO.discard(file) }
        let thumbnail = try await TelegramUploadVideoIO.thumbnail(file)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, "public.jpeg")
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 160); XCTAssertEqual(image.height, 320)
        XCTAssertEqual(thumbnail.width, 160); XCTAssertEqual(thumbnail.height, 320)
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testVideoChosenAsOrdinaryFileCannotAcquireVideoThumbnail() async throws {
        let source = try source()
        try await writeUploadVideoFixture(source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        defer { try? TelegramUploadFileIO.discard(file) }
        do { _ = try await TelegramUploadVideoIO.thumbnail(file); XCTFail("Ordinary file acquired a video thumbnail") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidVideo) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    private func source() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("portrait.mov")
    }
}

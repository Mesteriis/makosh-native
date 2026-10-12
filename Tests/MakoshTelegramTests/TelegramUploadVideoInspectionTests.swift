import XCTest
import AVFoundation
import CoreVideo
@testable import MakoshTelegram

@MainActor
final class TelegramUploadVideoInspectionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }


    func testOwnedMP4InspectionReadsDisplayGeometryWithoutChangingSourceOrStage() async throws {
        let source = try directory().appendingPathComponent("portrait.mp4")
        try await writeUploadVideoFixture(source, rotated: true)
        let original = try Data(contentsOf: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        defer { try? TelegramUploadFileIO.discard(file) }
        let info = try await TelegramUploadVideoIO.inspect(file)
        XCTAssertEqual(info.width, 16); XCTAssertEqual(info.height, 32)
        XCTAssertEqual(info.duration, 1, accuracy: 0.05)
        XCTAssertFalse(info.hasAudio)
        XCTAssertTrue(info.animationEligible, "The final Animated flag also depends on the preparation's collage choice")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: file.url), original)
    }

    func testMOVSourceDoesNotAcquireMP4AnimationEligibility() async throws {
        let source = try directory().appendingPathComponent("original.mov")
        try await writeUploadVideoFixture(source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        defer { try? TelegramUploadFileIO.discard(file) }
        let info = try await TelegramUploadVideoIO.inspect(file)
        XCTAssertEqual(info.width, 32); XCTAssertEqual(info.height, 16)
        XCTAssertFalse(info.animationEligible)
        XCTAssertEqual(file.name, "original.mov")
    }

    func testDurationMatchesNativeFloat32RoundTripForExactReceipts() async throws {
        let source = try directory().appendingPathComponent("fractional.mp4")
        try await writeUploadVideoFixture(source, timescale: 30)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        defer { try? TelegramUploadFileIO.discard(file) }
        let info = try await TelegramUploadVideoIO.inspect(file)
        // Ten frames at30Hz =1/3s; native Postbox/FlatBuffers decodes Float32.
        XCTAssertEqual(info.duration, 0.3333333432674408)
    }

    func testCorruptAndAudioOnlyInputsCannotBecomeVideo() async throws {
        let root = try directory()
        let corrupt = root.appendingPathComponent("corrupt.mp4")
        try Data("not video".utf8).write(to: corrupt)
        let audio = root.appendingPathComponent("audio.wav")
        try await TelegramSyntheticPlaybackFixtures.write(kind: .audio, to: audio)
        for url in [corrupt, audio] {
            let file = try await TelegramUploadFileIO.stage(url, mode: .file)
            defer { try? TelegramUploadFileIO.discard(file) }
            do { _ = try await TelegramUploadVideoIO.inspect(file); XCTFail("Expected video rejection") }
            catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidVideo) }
        }
    }

    func testInspectionRefusesForeignAndRemovedOwnedStages() async throws {
        let source = try directory().appendingPathComponent("source.mp4")
        try await writeUploadVideoFixture(source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        let forged = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: source, directory: file.directory)
        do { _ = try await TelegramUploadVideoIO.inspect(forged); XCTFail("Foreign paths must fail") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        try TelegramUploadFileIO.discard(file)
        do { _ = try await TelegramUploadVideoIO.inspect(file); XCTFail("Removed stage must fail") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAlreadyCancelledInspectionPreservesOwnedStage() async throws {
        let source = try directory().appendingPathComponent("source.mp4")
        try await writeUploadVideoFixture(source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        defer { try? TelegramUploadFileIO.discard(file) }
        let original = try Data(contentsOf: file.url)
        let task = Task { @MainActor in try await TelegramUploadVideoIO.inspect(file) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation error") }
        XCTAssertEqual(try Data(contentsOf: file.url), original)
    }

    func testVideoStageFreezesCanonicalMetadataAndKeepsOriginalBytesAndName() async throws {
        let source = try directory().appendingPathComponent("portrait.mov")
        try await writeUploadVideoFixture(source, rotated: true, timescale: 30)
        let original = try Data(contentsOf: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .video)
        defer { try? TelegramUploadFileIO.discard(file) }
        XCTAssertEqual(file.mode, .video)
        XCTAssertEqual(file.name, "portrait.mov")
        XCTAssertEqual(file.pixelWidth, 16); XCTAssertEqual(file.pixelHeight, 32)
        let video = try XCTUnwrap(file.video)
        XCTAssertEqual(video.width, 16); XCTAssertEqual(video.height, 32)
        XCTAssertEqual(video.duration, 0.3333333432674408)
        XCTAssertFalse(video.hasAudio)
        XCTAssertTrue(video.inCollage, "Fresh singleton preparation follows the reference collage choice")
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testRestoredVideoMustMatchFrozenMetadataAndCannotRetypeOrdinaryFiles() async throws {
        let source = try directory().appendingPathComponent("source.mp4")
        try await writeUploadVideoFixture(source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .video)
        defer { try? TelegramUploadFileIO.discard(file) }
        let video = try XCTUnwrap(file.video)
        let restored = try await TelegramUploadFileIO.restoredStage(id: file.id, name: file.name,
            size: file.size, mode: .video, url: file.url, directory: file.directory, video: video)
        XCTAssertEqual(restored.video, video)
        XCTAssertEqual(restored.pixelWidth, 32); XCTAssertEqual(restored.pixelHeight, 16)
        let altered = TelegramUploadVideoMetadata(width: 31, height: 16, duration: 1, hasAudio: false, inCollage: true)
        for metadata in [nil, altered] {
            do {
                _ = try await TelegramUploadFileIO.restoredStage(id: file.id, name: file.name,
                    size: file.size, mode: .video, url: file.url, directory: file.directory, video: metadata)
                XCTFail("A missing/mismatched frozen descriptor must fail closed")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidVideo) }
        }
        do {
            _ = try await TelegramUploadFileIO.restoredStage(id: file.id, name: file.name,
                size: file.size, mode: .file, url: file.url, directory: file.directory, video: video)
            XCTFail("Video metadata cannot reinterpret an ordinary file")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }
}

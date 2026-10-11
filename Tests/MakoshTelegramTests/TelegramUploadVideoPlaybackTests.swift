import XCTest
import AVFoundation
@testable import MakoshTelegram

@MainActor
final class TelegramUploadVideoPlaybackTests: XCTestCase {
    private enum Failure: Error { case deadline }
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Video preview deadline"); throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func source(_ suffix: String = "mov", timescale: Int32 = 10) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("portrait." + suffix)
        try await writeUploadVideoFixture(url, rotated: true, timescale: timescale)
        return url
    }

    // Catches opening the picker URL, audible autoplay, missing visibility gating,
    // or leaving the decoder attached after the preparation is stopped.
    func testOwnedMOVAndMP4PlayMutedOnlyWhileVisibleAndStopWithoutConsumingStage() async throws {
        for suffix in ["mov", "mp4"] {
            let url = try await source(suffix)
            let original = try Data(contentsOf: url)
            let file = try await TelegramUploadFileIO.stage(url, mode: .video)
            defer { try? TelegramUploadFileIO.discard(file) }
            let playback = TelegramUploadVideoPlaybackController()
            await playback.load(file)
            let player = try XCTUnwrap(playback.player)
            XCTAssertNil(playback.error)
            XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, file.url)
            XCTAssertEqual(player.volume, 0)
            XCTAssertTrue(player.isMuted)
            XCTAssertFalse(player.allowsExternalPlayback)
            XCTAssertEqual(player.rate, 0)
            playback.setVisible(true, player: player)
            try await eventually { player.currentTime().seconds > 0.05 }
            playback.setVisible(false, player: player)
            XCTAssertEqual(player.rate, 0)
            playback.stop()
            XCTAssertNil(playback.player); XCTAssertNil(player.currentItem)
            playback.setVisible(true, player: player)
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(try Data(contentsOf: file.url), original)
        }
    }

    // Catches the existing received-media end handler detaching the upload
    // preview after one pass instead of repeating the visible muted video.
    func testVisibleVideoRepeatsAndStaleViewCannotPauseItsReplacement() async throws {
        let first = try await TelegramUploadFileIO.stage(source(timescale: 50), mode: .video)
        defer { try? TelegramUploadFileIO.discard(first) }
        let playback = TelegramUploadVideoPlaybackController()
        await playback.load(first)
        let old = try XCTUnwrap(playback.player)
        playback.setVisible(true, player: old)
        var previous = 0.0, wraps = 0
        try await eventually {
            let current = old.currentTime().seconds
            if current + 0.03 < previous { wraps += 1 }
            previous = current
            return wraps >= 2
        }
        XCTAssertNotNil(old.currentItem)
        let second = try await TelegramUploadFileIO.stage(source("mp4"), mode: .video)
        defer { try? TelegramUploadFileIO.discard(second) }
        await playback.load(second)
        let current = try XCTUnwrap(playback.player)
        XCTAssertNil(old.currentItem)
        playback.setVisible(true, player: current)
        playback.setVisible(false, player: old)
        XCTAssertEqual(current.rate, 1)
        playback.stop()
    }

    private final class Provider: TelegramUploadProvider {
        let accountID: Int64 = 1
        var onSubmit: (() -> Void)?
        private final class Lease: TelegramUploadLease { func stop() {} }
        func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID,
                    caption: TelegramFormattedText, captionAboveMedia: Bool, mediaSpoiler: Bool,
                    receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
            onSubmit?(); return Lease()
        }
    }

    // Catches unlink-before-detach and preview continuing under a spoiler or
    // during submission. The provider only observes the real upload boundary.
    func testSpoilerDismissRebindAndSendDetachActualPlayerBeforeReleaseOrSubmit() async throws {
        for boundary in 0..<4 {
            let url = try await source()
            let upload = TelegramUploadController(), provider = Provider()
            upload.bind(provider: provider)
            upload.prepare(source: url, mode: .video,
                target: TelegramUploadTarget(accountID: 1, chatID: 2, title: "Synthetic"), caption: "caption")
            try await eventually { upload.phase == .ready }
            let context = try XCTUnwrap(upload.preparationContextID)
            let stage = try XCTUnwrap(upload.file)
            await upload.openVideoPreview(contextID: UUID())
            XCTAssertNil(upload.videoPlayback.player)
            await upload.openVideoPreview(contextID: context)
            let player = try XCTUnwrap(upload.videoPlayback.player)
            var releases = 0, submissions = 0
            upload.discard = { file in
                XCTAssertNil(player.currentItem, "Decoder must detach before unlink")
                releases += 1; try TelegramUploadFileIO.discard(file)
            }
            provider.onSubmit = {
                XCTAssertNil(player.currentItem, "Decoder must detach before submit")
                submissions += 1
            }
            switch boundary {
            case 0:
                XCTAssertTrue(upload.updateMediaSpoiler(true, contextID: upload.captionContextID, revision: upload.captionRevision))
                await upload.openVideoPreview(contextID: context)
                XCTAssertNil(upload.videoPlayback.player)
                XCTAssertTrue(FileManager.default.fileExists(atPath: stage.url.path))
            case 1: upload.dismissPreparation(contextID: context)
            case 2: upload.bind(provider: nil)
            default: upload.send(contextID: context)
            }
            XCTAssertNil(player.currentItem); XCTAssertNil(upload.videoPlayback.player)
            XCTAssertEqual(submissions, boundary == 3 ? 1 : 0)
            if boundary == 1 || boundary == 2 { XCTAssertEqual(releases, 1) }
            upload.clear()
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testMissingMetadataRemovedStageAndCancellationCannotPublishPlayer() async throws {
        let file = try await TelegramUploadFileIO.stage(source(), mode: .video)
        let missing = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .video,
            pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: file.url, directory: file.directory)
        let playback = TelegramUploadVideoPlaybackController()
        await playback.load(missing)
        XCTAssertNil(playback.player); XCTAssertNotNil(playback.error)
        let cancelled = Task { await playback.load(file) }
        cancelled.cancel(); await cancelled.value
        XCTAssertNil(playback.player)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        try TelegramUploadFileIO.discard(file)
        await playback.load(file)
        XCTAssertNil(playback.player); XCTAssertNotNil(playback.error)
    }
}

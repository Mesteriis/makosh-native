import XCTest
import AVFoundation
import CryptoKit
@testable import MakoshTelegram

@MainActor final class TelegramRoundVideoPlaybackTests: XCTestCase {
    private enum Failure: Error { case deadline }
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Round preview deadline"); throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func fixture(duration: Double = 0.6, once: Bool = false) async throws -> TelegramUploadFile {
        try await TelegramRecordedRoundVideoIO.prepare(bytes: recordedRoundVideoFixtureBytes(side: 64, duration: duration), isOneTime: once)
    }
    private func copy(_ file: TelegramUploadFile, video: TelegramUploadVideoMetadata? = nil,
                      metadata: TelegramUploadMetadata?? = nil, name: String? = nil) -> TelegramUploadFile {
        .init(id: file.id, name: name ?? file.name, size: file.size, mode: file.mode,
            pixelWidth: video?.width ?? file.pixelWidth, pixelHeight: video?.height ?? file.pixelHeight,
            url: file.url, directory: file.directory, video: video ?? file.video, metadata: metadata ?? file.metadata)
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    // Catches routing an extensionless round stage through generic MIME, audible/external
    // playback, autoplay, or consuming immutable ordinary/once preparation bytes.
    func testOrdinaryAndOncePreviewBorrowExactBytesMutedOnlyWhileVisible() async throws {
        for once in [false, true] {
            let file = try await fixture(once: once); defer { try? TelegramUploadFileIO.discard(file) }
            let bytes = try Data(contentsOf: file.url)
            let members = try FileManager.default.contentsOfDirectory(atPath: file.directory.path)
            let playback = TelegramUploadVideoPlaybackController(); defer { playback.stop() }
            await playback.loadRoundVideo(file)
            guard let player = playback.player else { XCTFail("Explicit round preview missing"); continue }
            XCTAssertNil(playback.error)
            XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, file.url)
            XCTAssertTrue(player.isMuted); XCTAssertEqual(player.volume, 0)
            XCTAssertFalse(player.allowsExternalPlayback); XCTAssertEqual(player.rate, 0)
            playback.setVisible(true, player: player)
            try await eventually { player.currentTime().seconds > 0.05 }
            playback.setVisible(false, player: player); XCTAssertEqual(player.rate, 0)
            playback.stop(); XCTAssertNil(playback.player); XCTAssertNil(player.currentItem)
            playback.setVisible(true, player: player); XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(file.metadata?.roundVideo?.isOneTime, once)
            XCTAssertEqual(try Data(contentsOf: file.url), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.directory.path), members)
        }
    }

    // Catches silently treating an explicitly typed round preparation as generic video.
    func testGenericLoadRefusesTypedRoundWhilePreservingItsStage() async throws {
        let file = try await fixture(); defer { try? TelegramUploadFileIO.discard(file) }
        let bytes = try Data(contentsOf: file.url)
        let playback = TelegramUploadVideoPlaybackController(); defer { playback.stop() }
        await playback.load(file)
        XCTAssertNil(playback.player); XCTAssertNotNil(playback.error)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    // Catches trusting frozen metadata, a round flag, or a matching digest without
    // independently validating actual AAC rate/track profile and decoded facts.
    func testExplicitLoadRejectsMetadataDigestAndActualProfileMismatch() async throws {
        let file = try await fixture(); defer { try? TelegramUploadFileIO.discard(file) }
        let video = try XCTUnwrap(file.video), round = try XCTUnwrap(file.metadata?.roundVideo)
        let variants = [
            copy(file, metadata: .some(nil)),
            copy(file, metadata: .roundVideo(.init(nativeDuration: 1, plaintextSHA256: String(repeating: "0", count: 64)))),
            copy(file, metadata: .roundVideo(.init(nativeDuration: 2, plaintextSHA256: round.plaintextSHA256))),
            copy(file, video: .init(width: 64, height: 64, duration: 0.7, hasAudio: true, inCollage: false)),
            copy(file, video: .init(width: video.width, height: video.height, duration: video.duration, hasAudio: false, inCollage: false)),
            copy(file, name: "picked.mp4")
        ]
        let playback = TelegramUploadVideoPlaybackController(); defer { playback.stop() }
        for variant in variants {
            await playback.loadRoundVideo(variant)
            XCTAssertNil(playback.player); XCTAssertNotNil(playback.error)
        }
        let bytes = try await recordedRoundVideoFixtureBytes(side: 64, duration: 0.6, rate: 48_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("picked.mp4"); try bytes.write(to: url)
        let generic = try await TelegramUploadFileIO.stage(url, mode: .video)
        defer { try? TelegramUploadFileIO.discard(generic) }
        let forged = copy(generic, metadata: .roundVideo(.init(nativeDuration: 1, plaintextSHA256: hash(bytes))), name: "RoundVideo.mp4")
        await playback.loadRoundVideo(forged)
        XCTAssertNil(playback.player); XCTAssertNotNil(playback.error)
        XCTAssertEqual(try Data(contentsOf: generic.url), bytes)
    }

    // Catches a valid descriptor/digest being accepted after physical bytes change.
    func testChangedStageBytesAreRefusedWithoutConsumingPreparation() async throws {
        let file = try await fixture(); defer { try? TelegramUploadFileIO.discard(file) }
        var bytes = try Data(contentsOf: file.url); bytes[0] ^= 0xff
        try bytes.write(to: file.url)
        let playback = TelegramUploadVideoPlaybackController(); defer { playback.stop() }
        await playback.loadRoundVideo(file)
        XCTAssertNil(playback.player); XCTAssertNotNil(playback.error)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    // Catches detaching at end, replaying a hidden preview, or stale view/native
    // events changing the replacement's transport after a visible loop.
    func testVisibleRoundLoopsAndStaleViewsOrEventsCannotAffectReplacement() async throws {
        let first = try await fixture(duration: 0.5), second = try await fixture(once: true)
        defer { try? TelegramUploadFileIO.discard(first); try? TelegramUploadFileIO.discard(second) }
        let playback = TelegramUploadVideoPlaybackController(); defer { playback.stop() }
        await playback.loadRoundVideo(first)
        guard let old = playback.player, let oldItem = old.currentItem else { XCTFail("Round loop preview missing"); return }
        playback.setVisible(true, player: old)
        var previous = 0.0, wraps = 0
        try await eventually {
            let current = old.currentTime().seconds
            if current + 0.03 < previous { wraps += 1 }
            previous = current; return wraps >= 2
        }
        XCTAssertNotNil(old.currentItem)
        playback.setVisible(false, player: old)
        playback.repeatIfVisible(player: old)
        XCTAssertEqual(old.rate, 0); XCTAssertNotNil(old.currentItem)
        await playback.loadRoundVideo(second)
        guard let current = playback.player else { XCTFail("Replacement round preview missing"); return }
        XCTAssertNil(old.currentItem)
        playback.setVisible(true, player: current)
        playback.setVisible(false, player: old)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: oldItem)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(playback.player === current); XCTAssertNotNil(current.currentItem)
        XCTAssertEqual(current.rate, 1); XCTAssertEqual(current.volume, 0)
        XCTAssertEqual((current.currentItem?.asset as? AVURLAsset)?.url, second.url)
    }

    // Catches a cancelled/stopped decoder publishing after inspection, or a stale
    // load replacing a newer round asset. Every operation borrows the same stage.
    func testStopCancellationAndStaleLoadingCannotPublishOrConsumeBytes() async throws {
        let first = try await fixture(duration: 2), second = try await fixture(once: true)
        defer { try? TelegramUploadFileIO.discard(first); try? TelegramUploadFileIO.discard(second) }
        let bytes = try Data(contentsOf: first.url)
        let playback = TelegramUploadVideoPlaybackController(); defer { playback.stop() }
        var stopEntered = false
        let stopped = Task { stopEntered = true; await playback.loadRoundVideo(first) }
        while !stopEntered { await Task.yield() }
        playback.stop(); await stopped.value
        XCTAssertNil(playback.player); XCTAssertNil(playback.error)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await playback.loadRoundVideo(first)
        }
        await cancelled.value
        XCTAssertNil(playback.player); XCTAssertNil(playback.error)
        var staleEntered = false
        let stale = Task { staleEntered = true; await playback.loadRoundVideo(first) }
        while !staleEntered { await Task.yield() }
        await playback.loadRoundVideo(second); await stale.value
        guard let current = playback.player else { XCTFail("Current round lost after stale loading"); return }
        XCTAssertEqual((current.currentItem?.asset as? AVURLAsset)?.url, second.url)
        XCTAssertEqual(try Data(contentsOf: first.url), bytes)
        playback.stop(); XCTAssertNil(current.currentItem)
    }

    // Catches an already-cancelled, obsolete request detaching a ready replacement.
    func testAlreadyCancelledLoadLeavesCurrentRoundPreviewIntact() async throws {
        let currentFile = try await fixture(once: true), cancelledFile = try await fixture()
        defer { try? TelegramUploadFileIO.discard(currentFile); try? TelegramUploadFileIO.discard(cancelledFile) }
        let currentBytes = try Data(contentsOf: currentFile.url), cancelledBytes = try Data(contentsOf: cancelledFile.url)
        let playback = TelegramUploadVideoPlaybackController(); defer { playback.stop() }
        await playback.loadRoundVideo(currentFile)
        let player = try XCTUnwrap(playback.player), item = try XCTUnwrap(player.currentItem)
        playback.setVisible(true, player: player)
        let obsolete = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await playback.loadRoundVideo(cancelledFile)
        }
        await obsolete.value
        XCTAssertTrue(playback.player === player); XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(player.rate, 1); XCTAssertNil(playback.error)
        XCTAssertEqual(try Data(contentsOf: currentFile.url), currentBytes)
        XCTAssertEqual(try Data(contentsOf: cancelledFile.url), cancelledBytes)
    }
}

import XCTest
import AVFoundation
@testable import MakoshTelegram

@MainActor final class TelegramUploadVideoLoopTests: XCTestCase {
    private func fixture() async throws -> TelegramUploadFile {
        try await TelegramRecordedRoundVideoIO.prepare(
            bytes: recordedRoundVideoFixtureBytes(side: 64, duration: 2), isOneTime: false)
    }

    // Catches restarting before a seek finishes, or seeking/restarting a hidden preview.
    func testHeldLoopSeekStaysPausedAfterHideAndHiddenEndDoesNotSeek() async throws {
        let file = try await fixture(); defer { try? TelegramUploadFileIO.discard(file) }
        let bytes = try Data(contentsOf: file.url)
        var completions: [@MainActor (Bool) -> Void] = []
        let playback = TelegramUploadVideoPlaybackController(seekToStart: { _, completion in
            completions.append(completion)
        })
        defer { playback.stop() }
        await playback.loadRoundVideo(file)
        let player = try XCTUnwrap(playback.player), item = try XCTUnwrap(player.currentItem)
        playback.setVisible(true, player: player)
        playback.repeatIfVisible(player: player)
        XCTAssertEqual(player.rate, 0, "Pause before starting an asynchronous loop seek")
        XCTAssertEqual(completions.count, 1)
        playback.setVisible(false, player: player)
        try XCTUnwrap(completions.first)(true)
        XCTAssertEqual(player.rate, 0)
        playback.repeatIfVisible(player: player)
        XCTAssertEqual(completions.count, 1, "Hidden EOF must not initiate another seek")
        XCTAssertEqual(player.rate, 0); XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    // Catches interrupted seeks autoplaying, duplicate EOF starting concurrent seeks,
    // or a visibility update starting playback while the loop seek is pending.
    func testVisibleLoopWaitsForSuccessfulCurrentSeekCompletion() async throws {
        let file = try await fixture(); defer { try? TelegramUploadFileIO.discard(file) }
        for (finished, expectedRate) in [(true, Float(1)), (false, Float(0))] {
            var completions: [@MainActor (Bool) -> Void] = []
            let playback = TelegramUploadVideoPlaybackController(seekToStart: { _, completion in
                completions.append(completion)
            })
            defer { playback.stop() }
            await playback.loadRoundVideo(file)
            let player = try XCTUnwrap(playback.player)
            playback.setVisible(true, player: player)
            playback.repeatIfVisible(player: player)
            playback.repeatIfVisible(player: player)
            playback.setVisible(false, player: player)
            playback.setVisible(true, player: player)
            XCTAssertEqual(completions.count, 1)
            XCTAssertEqual(player.rate, 0)
            try XCTUnwrap(completions.first)(finished)
            XCTAssertEqual(player.rate, expectedRate)
            XCTAssertNotNil(player.currentItem)
        }
    }

    // Catches an old seek completion reviving a stopped player or changing its replacement.
    func testLateLoopCompletionCannotReviveStoppedOrReplacedPlayer() async throws {
        let first = try await fixture(), second = try await fixture()
        defer { try? TelegramUploadFileIO.discard(first); try? TelegramUploadFileIO.discard(second) }
        let firstBytes = try Data(contentsOf: first.url), secondBytes = try Data(contentsOf: second.url)
        for replace in [false, true] {
            var completion: (@MainActor (Bool) -> Void)?
            let playback = TelegramUploadVideoPlaybackController(seekToStart: { _, callback in completion = callback })
            defer { playback.stop() }
            await playback.loadRoundVideo(first)
            let old = try XCTUnwrap(playback.player)
            playback.setVisible(true, player: old)
            playback.repeatIfVisible(player: old)
            let finish = try XCTUnwrap(completion)
            if replace {
                await playback.loadRoundVideo(second)
                let current = try XCTUnwrap(playback.player)
                playback.setVisible(true, player: current)
                finish(true)
                playback.repeatIfVisible(player: old)
                XCTAssertTrue(playback.player === current); XCTAssertEqual(current.rate, 1)
                XCTAssertEqual((current.currentItem?.asset as? AVURLAsset)?.url, second.url)
            } else {
                playback.stop(); finish(true)
                XCTAssertNil(playback.player)
            }
            XCTAssertNil(old.currentItem); XCTAssertEqual(old.rate, 0)
        }
        XCTAssertEqual(try Data(contentsOf: first.url), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second.url), secondBytes)
    }
}

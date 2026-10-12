import XCTest
import Foundation
import AVFoundation
@testable import MakoshTelegram

@MainActor final class TelegramPlaybackControllerTests: XCTestCase {
    private final class Lease: TelegramMediaLease {
        var cancellations = 0
        func cancel() { cancellations += 1 }
    }
    private final class Provider: TelegramMediaProvider {
        let lease = Lease()
        let url: URL
        var purposes: [TelegramMediaPurpose] = []
        init(url: URL) { self.url = url }
        func start(attachmentID: String, purpose: TelegramMediaPurpose,
                   receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            purposes.append(purpose)
            receive(.data(url, offset: 0, size: 3, complete: true))
            return lease
        }
    }
    private final class Engine: TelegramPlaybackEngine {
        var player: AVPlayer? { nil }
        var loaded: URL?
        var kind: TelegramPlaybackKind?
        var receive: (@MainActor (TelegramPlaybackEvent) -> Void)?
        var pending: CheckedContinuation<TelegramPlaybackInfo, Error>?
        var plays: [Float] = [], seeks: [Double] = []
        var pauses = 0, stops = 0
        func load(file: URL, kind: TelegramPlaybackKind,
                  receive: @escaping @MainActor (TelegramPlaybackEvent) -> Void) async throws -> TelegramPlaybackInfo {
            loaded = file; self.kind = kind; self.receive = receive
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func complete() {
            let old = pending; pending = nil
            old?.resume(returning: TelegramPlaybackInfo(duration: 10, hasVideo: false))
        }
        func play(rate: Float) { plays.append(rate) }
        func pause() { pauses += 1 }
        func seek(seconds: Double) { seeks.append(seconds) }
        func setVolume(_ volume: Float) { }
        func stop() {
            stops += 1
            let old = pending; pending = nil
            old?.resume(throwing: CancellationError())
        }
    }
    private func attachment(playback: TelegramPlaybackKind? = .audio, name: String = "fixture") -> TelegramAttachment {
        TelegramAttachment(id: "fixture", kind: .file, name: name, byteCount: 3,
                           mimeType: "audio/test", hasPreview: true, canDownload: true, playback: playback)
    }
    private func setup() throws -> (TelegramMediaController, Provider) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source")
        try Data([1, 2, 3]).write(to: url)
        let provider = Provider(url: url), media = TelegramMediaController()
        media.bind(provider: provider); media.retain(attachments: [attachment()])
        return (media, provider)
    }
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testNoAutomaticFetchAndOnlyFullReadyCanOpen() async throws {
        let (media, provider) = try setup()
        let engine = Engine(); var created = 0
        let controller = TelegramPlaybackController { created += 1; return engine }
        controller.retain(attachments: [attachment()])
        controller.open(attachment: attachment(), media: media)
        XCTAssertEqual(created, 0); XCTAssertTrue(provider.purposes.isEmpty)
        media.start(attachment(), purpose: .preview)
        controller.open(attachment: attachment(), media: media)
        XCTAssertEqual(created, 0)
        media.start(attachment(), purpose: .full)
        controller.open(attachment: attachment(playback: nil), media: media)
        XCTAssertEqual(created, 0)
        controller.open(attachment: attachment(), media: media)
        controller.open(attachment: attachment(), media: media)
        await eventually { engine.pending != nil }
        XCTAssertEqual(created, 1); XCTAssertEqual(engine.kind, .audio)
        XCTAssertNotEqual(engine.loaded, provider.url)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(engine.loaded)), Data([1, 2, 3]))
        controller.stop(); await eventually { !controller.isBusy }
    }

    func testBorrowSpansLoadReadyPauseAndStopDeletesPrivateCopy() async throws {
        let (media, provider) = try setup(); media.start(attachment(), purpose: .full)
        let engine = Engine(), controller = TelegramPlaybackController { engine }
        controller.open(attachment: attachment(), media: media)
        await eventually { engine.pending != nil }
        XCTAssertEqual(controller.phase, .loading)
        media.reset(); XCTAssertEqual(provider.lease.cancellations, 0)
        engine.complete(); await eventually { controller.phase == .ready }
        XCTAssertEqual(controller.duration, 10)
        controller.togglePlayback(); XCTAssertEqual(engine.plays, [1])
        engine.receive?(.transport(.playing)); controller.togglePlayback()
        XCTAssertEqual(engine.pauses, 1)
        engine.receive?(.transport(.paused)); XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(provider.lease.cancellations, 0)
        let copy = try XCTUnwrap(engine.loaded)
        controller.stop(); controller.stop()
        await eventually { !controller.isBusy }
        XCTAssertEqual(provider.lease.cancellations, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: provider.url), Data([1, 2, 3]))
        engine.receive?(.transport(.playing)); XCTAssertEqual(controller.phase, .idle)
    }

    func testDeadlineCancelsPendingLoadAndStaleEventsCannotRevive() async throws {
        let (media, provider) = try setup(); media.start(attachment(), purpose: .full)
        let engine = Engine(), controller = TelegramPlaybackController { engine }
        controller.open(attachment: attachment(), media: media)
        await eventually { engine.pending != nil }
        media.reset(); controller.expireLoading()
        await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .timedOut); XCTAssertNotNil(controller.error)
        XCTAssertNil(engine.pending); XCTAssertEqual(provider.lease.cancellations, 1)
        engine.complete(); engine.receive?(.ended); engine.receive?(.transport(.playing))
        XCTAssertEqual(controller.phase, .timedOut)
    }

    func testEndAndFailureReleaseBorrowExactlyOnce() async throws {
        for failure in [false, true] {
            let (media, provider) = try setup(); media.start(attachment(), purpose: .full)
            let engine = Engine(), controller = TelegramPlaybackController { engine }
            controller.open(attachment: attachment(), media: media)
            await eventually { engine.pending != nil }
            engine.complete(); await eventually { controller.phase == .ready }
            media.reset()
            engine.receive?(failure ? .failed : .ended)
            await eventually { !controller.isBusy }
            XCTAssertEqual(controller.phase, failure ? .failed : .ended)
            XCTAssertEqual(provider.lease.cancellations, 1)
            engine.receive?(.failed); controller.stop()
            XCTAssertEqual(provider.lease.cancellations, 1)
        }
    }

    func testControlsClampAndChangedResourceStops() async throws {
        let (media, _) = try setup(); media.start(attachment(), purpose: .full)
        let engine = Engine(), controller = TelegramPlaybackController { engine }
        controller.open(attachment: attachment(), media: media)
        await eventually { engine.pending != nil }; engine.complete()
        await eventually { controller.phase == .ready }
        controller.seek(seconds: -.infinity); controller.seek(seconds: .nan)
        controller.seek(seconds: -2); controller.seek(seconds: 99)
        XCTAssertEqual(engine.seeks, [0, 10])
        engine.receive?(.position(.nan)); XCTAssertEqual(controller.position, 0)
        engine.receive?(.position(99)); XCTAssertEqual(controller.position, 10)
        engine.receive?(.transport(.waiting)); XCTAssertEqual(controller.phase, .buffering)
        controller.setRate(3); XCTAssertEqual(controller.rate, 1)
        controller.setRate(1.5); controller.togglePlayback(); XCTAssertEqual(engine.pauses, 1)
        controller.retain(attachments: [attachment()]); XCTAssertTrue(controller.isActive)
        controller.retain(attachments: [attachment(name: "changed")])
        await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .idle)
    }

    func testCleanupFailureRemainsVisibleAfterClosingAndNeverDeletesSymlinkTarget() async throws {
        let (media, provider) = try setup(); media.start(attachment(), purpose: .full)
        let engine = Engine(), controller = TelegramPlaybackController { engine }
        controller.open(attachment: attachment(), media: media)
        await eventually { engine.pending != nil }; engine.complete()
        await eventually { controller.phase == .ready }
        let directory = try XCTUnwrap(engine.loaded).deletingLastPathComponent()
        let saved = directory.appendingPathExtension("saved-test")
        try FileManager.default.moveItem(at: directory, to: saved)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: saved)
        }
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: provider.url.deletingLastPathComponent())
        controller.stop(); await eventually { !controller.isBusy }
        XCTAssertNil(controller.attachment)
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(try XCTUnwrap(controller.error).contains(directory.path))
        XCTAssertEqual(try Data(contentsOf: provider.url), Data([1, 2, 3]))
        controller.stop(); XCTAssertNil(controller.error)
    }
}

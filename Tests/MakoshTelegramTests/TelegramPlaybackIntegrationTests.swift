import Foundation
import XCTest
@testable import MakoshTelegram

#if DEBUG
@MainActor final class TelegramPlaybackIntegrationTests: XCTestCase {
    private enum Failure: Error { case deadline }
    private final class Lease: TelegramMediaLease {
        var cancellations = 0
        func cancel() { cancellations += 1 }
    }
    private final class Provider: TelegramMediaProvider {
        let url: URL
        let lease = Lease()
        init(url: URL) { self.url = url }
        func start(attachmentID: String, purpose: TelegramMediaPurpose,
                   receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            receive(.data(url, offset: 0, size: Int64(size), complete: true))
            return lease
        }
    }
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Playback deadline"); throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func setup() async throws -> (TelegramModel, Provider, TelegramAttachment) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("own-voice")
        try await TelegramSyntheticPlaybackFixtures.write(kind: .voice, to: url)
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let provider = Provider(url: url)
        model.media.bind(provider: provider)
        model.receiveMessages(model.messages, requestID: try XCTUnwrap(model.historyWindowID), previous: nil, next: nil, isLoading: false)
        let attachment = try XCTUnwrap(model.messages.flatMap(\.attachments).first { $0.playback == .voice })
        model.media.start(attachment, purpose: .full)
        model.playback.open(attachment: attachment, media: model.media)
        try await eventually { model.playback.phase == .ready || model.playback.phase == .paused }
        return (model, provider, attachment)
    }

    func testChatPageDisconnectAndViewCancellationStopActualNativePlayer() async throws {
        for boundary in 0..<4 {
            let (model, provider, _) = try await setup()
            let player = try XCTUnwrap(model.playback.player)
            XCTAssertEqual(player.rate, 0, "Opening must not autoplay")
            switch boundary {
            case 0: model.selectedChatID = model.chats.dropFirst().first?.id
            case 1: model.showLatestMessages()
            case 2: model.disconnect()
            default: model.cancelMediaLoads()
            }
            XCTAssertEqual(model.playback.phase, .idle)
            XCTAssertNil(player.currentItem)
            try await eventually { !model.playback.isBusy }
            model.media.reset()
            XCTAssertEqual(provider.lease.cancellations, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: provider.url.path))
        }
    }

    func testSameIDDescriptorReplacementStopsDecoderBeforeCacheRelease() async throws {
        let (model, provider, attachment) = try await setup()
        let player = try XCTUnwrap(model.playback.player)
        var messages = model.messages
        let index = try XCTUnwrap(messages.firstIndex { $0.attachments.contains(attachment) })
        messages[index].attachments = [TelegramAttachment(id: attachment.id, kind: .file, name: "replacement",
            byteCount: attachment.byteCount, mimeType: attachment.mimeType, hasPreview: false,
            canDownload: true, playback: .audio)]
        model.receiveMessages(messages, requestID: try XCTUnwrap(model.historyWindowID), previous: nil, next: nil, isLoading: false)
        XCTAssertEqual(model.playback.phase, .idle)
        XCTAssertNil(player.currentItem)
        try await eventually { !model.playback.isBusy }
        XCTAssertEqual(provider.lease.cancellations, 1)
    }
}
#endif

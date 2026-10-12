import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramVoiceOnceNativeTests: XCTestCase {
    private let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
    private func reference(voice: Bool = true) -> AnyMediaReference {
        .standalone(media: TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: 9),
            partialReference: nil, resource: LocalFileMediaResource(fileId: 9, size: 123),
            previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil,
            mimeType: "audio/ogg", size: nil,
            attributes: [.Audio(isVoice: voice, duration: 1, title: nil, performer: nil, waveform: nil)],
            alternativeRepresentations: []))
    }
    // The wire intent is independent of audio's duration and waveform. It must
    // be explicit, unique and never appear on ordinary voice uploads.
    func testViewOnceVoiceUsesNativeMaximumTimeoutWithoutCountdown() throws {
        let message = try XCTUnwrap(telegramUploadMessage(caption: try .init(text: ""), reference: reference(),
            target: target, replySource: nil, isOneTime: true))
        guard case let .message(_, attributes, _, _, _, _, _, _, _, _) = message else { return XCTFail("Expected media message") }
        let values = attributes.compactMap { $0 as? AutoremoveTimeoutMessageAttribute }
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.timeout, 2_147_483_647)
        XCTAssertEqual(values.first?.countdownBeginTime, 0)
        let ordinary = try XCTUnwrap(telegramUploadMessage(caption: try .init(text: ""), reference: reference(), target: target, replySource: nil))
        guard case let .message(_, ordinaryAttributes, _, _, _, _, _, _, _, _) = ordinary else { return XCTFail("Expected media message") }
        XCTAssertFalse(ordinaryAttributes.contains { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute })
    }
    // Explicit one-time intent may never downgrade to a file or text send.
    func testViewOnceRefusesNonVoiceCaptionSpoilerAndUnsupportedPeerShape() throws {
        XCTAssertNil(telegramUploadMessage(caption: try .init(text: ""), reference: reference(voice: false), target: target, replySource: nil, isOneTime: true))
        XCTAssertNil(telegramUploadMessage(caption: try .init(text: "Caption"), reference: reference(), target: target, replySource: nil, isOneTime: true))
        XCTAssertNil(telegramUploadMessage(caption: try .init(text: ""), reference: reference(), target: target, replySource: nil,
            mediaSpoiler: true, presentation: .file, isOneTime: true))
        XCTAssertNil(telegramUploadMessage(caption: try .init(text: ""), reference: reference(), target: target, replySource: nil,
            captionAboveMedia: true, presentation: .file, isOneTime: true))
        XCTAssertNil(telegramUploadMessage(caption: try .init(text: "Text"), reference: nil, target: target, replySource: nil, isOneTime: true))
        for chatID in [Int64(1), PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(7)).toInt64(),
            PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(8)).toInt64()] {
            XCTAssertNil(telegramUploadMessage(caption: try .init(text: ""), reference: reference(),
                target: .init(accountID: 1, chatID: chatID, title: "Synthetic"), replySource: nil, isOneTime: true))
        }
    }
}

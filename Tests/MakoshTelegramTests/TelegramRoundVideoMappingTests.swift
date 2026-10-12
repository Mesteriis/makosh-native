import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramRoundVideoMappingTests: XCTestCase {
    // Physical dimensions and Float32 duration are not the native200px/ceil facts.
    func testRoundMapsOnlyItsFrozenNativeVideoAttributeWithOptionalPreview() throws {
        initializeAccountManagement()
        for preview in [nil, TelegramUploadVideoThumbnailResource(id: 10, width: 300, height: 300, size: 50)] {
            let (_, reference) = try XCTUnwrap(telegramUploadMedia(fixture(), videoThumbnail: preview))
            let file = try XCTUnwrap(reference.media as? TelegramMediaFile)
            XCTAssertEqual(file.attributes, [.Video(duration: 2, size: PixelDimensions(width: 200, height: 200),
                flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)])
            XCTAssertEqual(file.mimeType, "video/mp4"); XCTAssertNil(file.size)
            XCTAssertEqual(file.previewRepresentations.count, preview == nil ? 0 : 1)
            XCTAssertTrue(file.videoThumbnails.isEmpty); XCTAssertTrue(file.alternativeRepresentations.isEmpty)
            XCTAssertNil(file.videoCover)
            let encoder = PostboxEncoder(); encoder.encodeRootObject(file)
            let restored = try XCTUnwrap(PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())).decodeRootObject() as? TelegramMediaFile)
            XCTAssertEqual(restored.attributes, file.attributes)
        }
        // Raw duration just above1 may round to1 in physical Float32 metadata.
        let nearInteger = try XCTUnwrap(telegramUploadMedia(fixture(duration: 1, nativeDuration: 2))?.1.media as? TelegramMediaFile)
        XCTAssertEqual(nearInteger.attributes, [.Video(duration: 2, size: PixelDimensions(width: 200, height: 200),
            flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)])
    }
    func testRoundRefusesCaptionOptionsAndFreezesOptionalOneTimeTTL() throws {
        let reference = try XCTUnwrap(telegramUploadMedia(fixture())?.1)
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic round")
        let empty = try TelegramFormattedText(text: "")
        XCTAssertNotNil(telegramUploadMessage(caption: empty, reference: reference, target: target, replySource: nil))
        XCTAssertNil(telegramUploadMessage(caption: try TelegramFormattedText(text: "Caption"), reference: reference, target: target, replySource: nil))
        XCTAssertNil(telegramUploadMessage(caption: empty, reference: reference, target: target, replySource: nil, captionAboveMedia: true))
        XCTAssertNil(telegramUploadMessage(caption: empty, reference: reference, target: target, replySource: nil, mediaSpoiler: true))
        let once = try XCTUnwrap(telegramUploadMessage(caption: empty, reference: reference, target: target, replySource: nil, isOneTime: true))
        guard case let .message(_, attributes, _, _, _, _, _, _, _, _) = once else { return XCTFail("Expected round message") }
        let ttl = attributes.compactMap { $0 as? AutoremoveTimeoutMessageAttribute }
        XCTAssertEqual(ttl.count, 1); XCTAssertEqual(ttl.first?.timeout, 2_147_483_647)
        XCTAssertEqual(ttl.first?.countdownBeginTime, 0)
    }
    func testRoundCannotDowngradeToGenericFileOrViolateRecordedBounds() throws {
        XCTAssertNil(TelegramUploadBatchItem(id: UUID(), file: fixture()).presented(as: .file))
        for invalid in [fixture(width: 300, height: 200), fixture(width: 1025, height: 1025),
            fixture(duration: 0.25), fixture(duration: 61), fixture(audio: false), fixture(collage: true),
            fixture(name: "picked.mp4"), fixture(size: 134_217_729), fixture(duration: 1.25, nativeDuration: 1),
            fixture(duration: 1.25, nativeDuration: 3)] {
            XCTAssertNil(telegramUploadMedia(invalid, videoThumbnail: .init(id: 10, width: 300, height: 300, size: 50)))
        }
        let picked = uploadVideoMappingFixture(name: "RoundVideo.mp4")
        let generic = try XCTUnwrap(telegramUploadMedia(picked, videoThumbnail: .init(id: 10, width: 16, height: 32, size: 50))?.1.media as? TelegramMediaFile)
        XCTAssertFalse(generic.isInstantVideo)
    }
    func testRoundPlanRefusesCaptionGroupingFileProjectionAndMixedItems() throws {
        let item = TelegramUploadBatchItem(id: UUID(), file: fixture())
        let empty = try TelegramFormattedText(text: "")
        XCTAssertNoThrow(try TelegramUploadBatchPlan(items: [item], isGrouped: false, caption: empty, presentation: .media))
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: [item], isGrouped: true, caption: empty, presentation: .media))
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: [item], isGrouped: false, caption: TelegramFormattedText(text: "Caption"), presentation: .media))
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: [item], isGrouped: false, caption: empty, captionAboveMedia: true, presentation: .media))
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: [item], isGrouped: false, caption: empty, mediaSpoiler: true, presentation: .media))
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: [item], isGrouped: false, caption: empty, presentation: .file))
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: [item], isGrouped: false, caption: empty))
        let second = TelegramUploadBatchItem(id: UUID(), file: fixture())
        XCTAssertThrowsError(try TelegramUploadBatchPlan(items: [item, second], isGrouped: false, caption: empty, presentation: .media))
    }
    private func fixture(width: Int32 = 300, height: Int32 = 300, duration: Double = 1.25,
        nativeDuration: Int32 = 2, audio: Bool = true, collage: Bool = false,
        name: String = "RoundVideo.mp4", size: Int64 = 42) -> TelegramUploadFile {
        let video = TelegramUploadVideoMetadata(width: width, height: height, duration: duration, hasAudio: audio, inCollage: collage)
        return TelegramUploadFile(id: UUID(), name: name, size: size, mode: .video,
            pixelWidth: width, pixelHeight: height, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"),
            video: video, metadata: .roundVideo(.init(nativeDuration: nativeDuration, plaintextSHA256: String(repeating: "a", count: 64))))
    }
}

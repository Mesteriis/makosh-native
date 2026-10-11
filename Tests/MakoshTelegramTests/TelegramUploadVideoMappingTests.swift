import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

func uploadVideoMappingFixture(name: String = "portrait.mov", size: Int64 = 42,
    inCollage: Bool = true, hasAudio: Bool = false, duration: Double = 0.3333333432674408) -> TelegramUploadFile {
    let video = TelegramUploadVideoMetadata(width: 16, height: 32, duration: duration, hasAudio: hasAudio, inCollage: inCollage)
    return TelegramUploadFile(id: UUID(), name: name, size: size, mode: .video,
        pixelWidth: 16, pixelHeight: 32, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"), video: video)
}

final class TelegramUploadVideoMappingTests: XCTestCase {
    func testMOVMapsToNativeVideoWithExactFloat32ReceiptMetadata() throws {
        initializeAccountManagement()
        let (resource, reference) = try XCTUnwrap(telegramUploadMedia(uploadVideoMappingFixture()))
        let file = try XCTUnwrap(reference.media as? TelegramMediaFile)
        XCTAssertEqual(file.mimeType, "video/mp4")
        XCTAssertEqual(file.size, 42)
        XCTAssertEqual(file.resource.id, resource.id)
        XCTAssertEqual(file.fileId.namespace, Namespaces.Media.LocalFile)
        XCTAssertEqual(file.attributes, [
            .Video(duration: 0.3333333432674408, size: PixelDimensions(width: 16, height: 32),
                flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil),
            .FileName(fileName: "portrait.mp4"), .hintFileIsLarge
        ])
        let encoder = PostboxEncoder(); encoder.encodeRootObject(file)
        let decoded = try XCTUnwrap(PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())).decodeRootObject() as? TelegramMediaFile)
        XCTAssertEqual(decoded.attributes, file.attributes, "Exact native receipt must survive Postbox's Float32 boundary")
        XCTAssertNil(file.partialReference)
    }

    func testAnimationUsesFrozenPreparationAndOriginalContainerSizeAndAudio() throws {
        for (name, size, collage, audio, animated) in [
            ("small.mp4", Int64(42), true, false, false),
            ("small.MP4", 42, false, false, true),
            ("large.mp4", 10 * 1024 * 1024, false, false, false),
            ("audio.mp4", 42, false, true, false),
            ("original.mov", 42, false, false, false)
        ] {
            let source = uploadVideoMappingFixture(name: name, size: size, inCollage: collage, hasAudio: audio)
            let file = try XCTUnwrap(telegramUploadMedia(source)?.1.media as? TelegramMediaFile)
            XCTAssertEqual(file.attributes.filter { $0 == .Animated }.count, animated ? 1 : 0, name)
            XCTAssertEqual(file.attributes.filter { $0 == .hintFileIsLarge }.count, name == "original.mov" ? 1 : 0)
        }
    }

    func testMissingMismatchedOrNoncanonicalVideoCannotBecomeNativeMedia() {
        let invalid = TelegramUploadFile(id: UUID(), name: "source.mp4", size: 42, mode: .video,
            pixelWidth: 16, pixelHeight: 32, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
        XCTAssertNil(telegramUploadMedia(invalid))
        XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture(duration: 1.0 / 3.0)))
        XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture(name: "audio.wav")))
        XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture(size: 0)))
        let descriptor = uploadVideoMappingFixture().video
        let mismatch = TelegramUploadFile(id: UUID(), name: "source.mp4", size: 42, mode: .video,
            pixelWidth: 32, pixelHeight: 16, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"), video: descriptor)
        XCTAssertNil(telegramUploadMedia(mismatch))
    }

    func testVideoSupportsRichCaptionPlacementAndSpoilerTogether() throws {
        let reference = try XCTUnwrap(telegramUploadMedia(uploadVideoMappingFixture())).1
        let caption = try TelegramFormattedText(text: "e\u{301} 😀", entities: [.init(offset: 3, length: 2, kind: .bold)])
        let message = try XCTUnwrap(telegramUploadMessage(caption: caption, reference: reference,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), replySource: nil, captionAboveMedia: true, mediaSpoiler: true))
        guard case let .message(text, attributes, _, media, _, _, _, grouping, _, _) = message else { return XCTFail("Expected media message") }
        XCTAssertEqual(text, "e\u{301} 😀")
        XCTAssertEqual(attributes.filter { $0 is InvertMediaMessageAttribute }.count, 1)
        XCTAssertEqual(attributes.filter { $0 is MediaSpoilerMessageAttribute }.count, 1)
        XCTAssertEqual(attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities.first?.range, 3..<5)
        XCTAssertTrue(media?.media is TelegramMediaFile)
        XCTAssertNil(grouping)
    }
}

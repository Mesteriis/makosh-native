import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

func uploadVideoMappingFixture(name: String = "portrait.mov", size: Int64 = 42,
    inCollage: Bool = true, hasAudio: Bool = false, duration: Double = 0.3333333432674408,
    videoCover: TelegramUploadVideoCover? = nil) -> TelegramUploadFile {
    let video = TelegramUploadVideoMetadata(width: 16, height: 32, duration: duration, hasAudio: hasAudio, inCollage: inCollage)
    return TelegramUploadFile(id: UUID(), name: name, size: size, mode: .video,
        pixelWidth: 16, pixelHeight: 32, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"), video: video, videoCover: videoCover)
}

final class TelegramUploadVideoMappingTests: XCTestCase {
    func testVideoRequiresOneBoundedDistinctLocalJPEGRepresentation() throws {
        let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 160, height: 320, size: 456)
        let (resource, reference) = try XCTUnwrap(telegramUploadMedia(uploadVideoMappingFixture(), videoThumbnail: thumbnail))
        let file = try XCTUnwrap(reference.media as? TelegramMediaFile)
        XCTAssertEqual(file.previewRepresentations.count, 1)
        let preview = try XCTUnwrap(file.previewRepresentations.first)
        XCTAssertEqual(preview.dimensions, PixelDimensions(width: 160, height: 320))
        let jpeg = try XCTUnwrap(preview.resource as? LocalFileMediaResource)
        XCTAssertEqual(jpeg.fileId, 123); XCTAssertEqual(jpeg.size, 456)
        XCTAssertNotEqual(jpeg.fileId, resource.fileId); XCTAssertFalse(jpeg.isSecretRelated)
        XCTAssertTrue(preview.progressiveSizes.isEmpty); XCTAssertNil(preview.immediateThumbnailData)
        XCTAssertFalse(preview.hasVideo); XCTAssertFalse(preview.isPersonal); XCTAssertEqual(preview.typeHint, .generic)
        XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture()))
        for invalid in [TelegramUploadVideoThumbnailResource(id: 123, width: 0, height: 320, size: 456),
                        .init(id: 123, width: 160, height: 321, size: 456),
                        .init(id: 123, width: 160, height: 320, size: 0),
                        .init(id: 123, width: 160, height: 320, size: 1_048_577)] {
            XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture(), videoThumbnail: invalid))
        }
        let ordinary = TelegramUploadFile(id: UUID(), name: "file.mp4", size: 42, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
        XCTAssertNil(telegramUploadMedia(ordinary, videoThumbnail: thumbnail))
        let photo = TelegramUploadFile(id: UUID(), name: "photo.jpg", size: 42, mode: .photo,
            pixelWidth: 16, pixelHeight: 32, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
        XCTAssertNil(telegramUploadMedia(photo, videoThumbnail: thumbnail))
    }
    func testMOVMapsToNativeVideoWithExactFloat32ReceiptMetadata() throws {
        initializeAccountManagement()
        let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 16, height: 32, size: 456)
        let (resource, reference) = try XCTUnwrap(telegramUploadMedia(uploadVideoMappingFixture(), videoThumbnail: thumbnail))
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
            let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 16, height: 32, size: 456)
            let file = try XCTUnwrap(telegramUploadMedia(source, videoThumbnail: thumbnail)?.1.media as? TelegramMediaFile)
            XCTAssertEqual(file.attributes.filter { $0 == .Animated }.count, animated ? 1 : 0, name)
            XCTAssertEqual(file.attributes.filter { $0 == .hintFileIsLarge }.count, name == "original.mov" ? 1 : 0)
        }
    }

    func testMissingMismatchedOrNoncanonicalVideoCannotBecomeNativeMedia() {
        let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 16, height: 32, size: 456)
        let invalid = TelegramUploadFile(id: UUID(), name: "source.mp4", size: 42, mode: .video,
            pixelWidth: 16, pixelHeight: 32, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
        XCTAssertNil(telegramUploadMedia(invalid, videoThumbnail: thumbnail))
        XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture(duration: 1.0 / 3.0), videoThumbnail: thumbnail))
        XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture(name: "audio.wav"), videoThumbnail: thumbnail))
        XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture(size: 0), videoThumbnail: thumbnail))
        let descriptor = uploadVideoMappingFixture().video
        let mismatch = TelegramUploadFile(id: UUID(), name: "source.mp4", size: 42, mode: .video,
            pixelWidth: 32, pixelHeight: 16, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"), video: descriptor)
        XCTAssertNil(telegramUploadMedia(mismatch, videoThumbnail: thumbnail))
    }

    func testVideoSupportsRichCaptionPlacementAndSpoilerTogether() throws {
        let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 16, height: 32, size: 456)
        let reference = try XCTUnwrap(telegramUploadMedia(uploadVideoMappingFixture(), videoThumbnail: thumbnail)).1
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

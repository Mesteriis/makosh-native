import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramUploadVideoCoverMappingTests: XCTestCase {
    private var staged: TelegramUploadVideoCover {
        .init(id: UUID(), width: 160, height: 320, size: 789, name: "cover.jpg",
            url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"), sha256: String(repeating: "a", count: 64))
    }
    // Catches substituting a cover for the first-frame thumbnail, or losing it
    // at the real TelegramMediaFile/Postbox boundary.
    func testCoverIsSeparateCanonicalImageAndSurvivesNativeRoundTrip() throws {
        initializeAccountManagement()
        let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 160, height: 320, size: 456)
        let cover = TelegramUploadVideoThumbnailResource(id: 124, width: 160, height: 320, size: 789)
        let (resource, reference) = try XCTUnwrap(telegramUploadMedia(uploadVideoMappingFixture(videoCover: staged), videoThumbnail: thumbnail, videoCover: cover))
        let file = try XCTUnwrap(reference.media as? TelegramMediaFile)
        XCTAssertEqual(file.previewRepresentations.count, 1)
        XCTAssertTrue(thumbnail.matches(try XCTUnwrap(file.previewRepresentations.first)))
        let image = try XCTUnwrap(file.videoCover)
        XCTAssertEqual(image.imageId, MediaId(namespace: 0, id: 0))
        XCTAssertEqual(image.representations.count, 1)
        XCTAssertTrue(cover.matches(try XCTUnwrap(image.representations.first)))
        XCTAssertNotEqual(resource.fileId, 123); XCTAssertNotEqual(resource.fileId, 124)
        XCTAssertNil(image.reference); XCTAssertNil(image.partialReference)
        XCTAssertNil(image.immediateThumbnailData); XCTAssertNil(image.emojiMarkup)
        XCTAssertTrue(image.flags.isEmpty); XCTAssertTrue(image.videoRepresentations.isEmpty)
        let encoder = PostboxEncoder(); encoder.encodeRootObject(file)
        let decoded = try XCTUnwrap(PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())).decodeRootObject() as? TelegramMediaFile)
        let decodedCover = try XCTUnwrap(decoded.videoCover)
        XCTAssertTrue(cover.matches(try XCTUnwrap(decodedCover.representations.first)))
        XCTAssertTrue(thumbnail.matches(try XCTUnwrap(decoded.previewRepresentations.first)))
    }

    // Catches aliasing two resources or admitting covers on ordinary documents
    // and photos, where the Telegram video-cover transport has no meaning.
    func testCoverRequiresBoundedDistinctVideoResource() {
        let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 160, height: 320, size: 456)
        for invalid in [thumbnail, .init(id: 124, width: 0, height: 320, size: 789),
            .init(id: 124, width: 160, height: 321, size: 789), .init(id: 124, width: 160, height: 320, size: 0),
            .init(id: 124, width: 160, height: 320, size: 1_048_577)] {
            XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture(videoCover: staged), videoThumbnail: thumbnail, videoCover: invalid))
        }
        let cover = TelegramUploadVideoThumbnailResource(id: 124, width: 160, height: 320, size: 789)
        for mode: TelegramUploadMode in [.file, .photo] {
            let file = TelegramUploadFile(id: UUID(), name: "synthetic.jpg", size: 42, mode: mode,
                pixelWidth: 16, pixelHeight: 32, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
            XCTAssertNil(telegramUploadMedia(file, videoCover: cover))
        }
    }

    func testTransportDescriptorMustMatchPreparedCover() {
        let file = uploadVideoMappingFixture(videoCover: staged)
        let thumbnail = TelegramUploadVideoThumbnailResource(id: 123, width: 160, height: 320, size: 456)
        XCTAssertNil(telegramUploadMedia(file, videoThumbnail: thumbnail))
        for changed in [TelegramUploadVideoThumbnailResource(id: 124, width: 159, height: 320, size: 789),
            .init(id: 124, width: 160, height: 320, size: 788)] {
            XCTAssertNil(telegramUploadMedia(file, videoThumbnail: thumbnail, videoCover: changed))
        }
        XCTAssertNil(telegramUploadMedia(uploadVideoMappingFixture(), videoThumbnail: thumbnail,
            videoCover: .init(id: 124, width: 160, height: 320, size: 789)))
    }
}

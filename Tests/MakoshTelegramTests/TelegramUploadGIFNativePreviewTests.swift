import XCTest
import Foundation
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramUploadGIFNativePreviewTests: XCTestCase {
    private func file(_ mode: TelegramUploadMode, typed: Bool = true) -> TelegramUploadFile {
        .init(id: UUID(), name: mode == .video ? "opaque.mp4" : "opaque.bin", size: 2048, mode: mode,
            pixelWidth: mode == .video ? 32 : nil, pixelHeight: mode == .video ? 16 : nil,
            url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"),
            video: mode == .video ? .init(width: 32, height: 16, duration: 0.75, hasAudio: false, inCollage: true) : nil,
            metadata: typed ? .gif(.init(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.4],
                sourceSHA256: String(repeating: "a", count: 64))) : nil)
    }
    private let preview = TelegramUploadVideoThumbnailResource(id: 77, width: 32, height: 16, size: 120)

    // Catches omission or hidden native flags in the distinct optional original-GIF JPEG role.
    func testGIFPreviewHasExactNativeRepresentationInBothModes() throws {
        initializeAccountManagement()
        for mode: TelegramUploadMode in [.file, .video] {
            let result = try XCTUnwrap(telegramUploadMedia(file(mode), gifPreview: preview, resourceID: 78))
            let native = try XCTUnwrap(result.1.media as? TelegramMediaFile)
            XCTAssertEqual(native.previewRepresentations.count, 1)
            let image = try XCTUnwrap(native.previewRepresentations.first)
            XCTAssertEqual(image.dimensions, .init(width: 32, height: 16))
            XCTAssertEqual((image.resource as? LocalFileMediaResource)?.fileId, 77)
            XCTAssertTrue(image.progressiveSizes.isEmpty); XCTAssertNil(image.immediateThumbnailData)
            XCTAssertFalse(image.hasVideo); XCTAssertFalse(image.isPersonal); XCTAssertEqual(image.typeHint, .generic)
            XCTAssertTrue(native.videoThumbnails.isEmpty); XCTAssertNil(native.videoCover)
            XCTAssertNotEqual(image.resource.id, native.resource.id)
        }
    }

    // Catches borrowed original identities, cross-kind JPEG roles and unsafe preview dimensions.
    func testGIFPreviewRejectsAliasesCrossKindAndOrdinaryVideoThumbnail() {
        initializeAccountManagement()
        for mode: TelegramUploadMode in [.file, .video] {
            XCTAssertNil(telegramUploadMedia(file(mode), gifPreview: preview, resourceID: 77))
            XCTAssertNil(telegramUploadMedia(file(mode), webPPreview: preview, gifPreview: preview))
            XCTAssertNil(telegramUploadMedia(file(mode), gifPreview: .init(id: 77, width: 321, height: 16, size: 120)))
            XCTAssertNil(telegramUploadMedia(file(mode), videoThumbnail: preview, gifPreview: preview))
        }
        XCTAssertNil(telegramUploadMedia(file(.file, typed: false), gifPreview: preview))
        XCTAssertNil(telegramUploadMedia(file(.video, typed: false), videoThumbnail: .init(id: 78, width: 32, height: 16, size: 120), gifPreview: preview))
    }
}

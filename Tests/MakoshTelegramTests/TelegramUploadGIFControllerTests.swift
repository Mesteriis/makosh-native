import XCTest
import Foundation
import CryptoKit
import Postbox
import TelegramCore
@testable import MakoshTelegram

@MainActor
final class TelegramUploadGIFControllerTests: XCTestCase {
    private func source(_ bytes: Data, name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(name); try bytes.write(to: url)
        return url
    }

    private var metadata: TelegramUploadMetadata {
        .gif(.init(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.4],
            sourceSHA256: SHA256.hash(data: uploadGIFTimingFixture).map { String(format: "%02x", $0) }.joined()))
    }

    // Catches suffix/photo precedence, lost originals and a File switch selecting MP4 bytes.
    func testControllerRetainsGIFAndMP4AcrossBothProjectionsAndMisleadingNames() async throws {
        for (name, mode): (String, TelegramUploadMode) in [("opaque.bin", .file), ("opaque.wav", .file), ("opaque.jpg", .photo)] {
            let url = try source(uploadGIFTimingFixture, name: name)
            let controller = TelegramUploadController(); defer { controller.clear() }
            controller.bind(provider: TelegramSyntheticUploadProvider())
            controller.prepare(sources: [.init(source: url, mode: mode)], isGrouped: false,
                target: .init(accountID: -1, chatID: 42, title: "Synthetic GIF"),
                captionInput: try .init(formattedText: .init(text: "GIF 😀")))
            for _ in 0..<1000 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(controller.phase, .ready)
            let item = try XCTUnwrap(controller.items.first)
            XCTAssertEqual(item.file.metadata, metadata); XCTAssertEqual(item.file.mode, .video)
            XCTAssertEqual(item.file.name, "opaque.mp4")
            XCTAssertFalse(controller.canEditVideoCover, "GIF conversion cannot carry the ordinary-video cover resource")
            let raw = try XCTUnwrap(item.originalFile)
            XCTAssertNil(raw.metadata); XCTAssertEqual(raw.name, name); XCTAssertNotEqual(raw.id, item.file.id)
            XCTAssertEqual(try Data(contentsOf: raw.url), uploadGIFTimingFixture)
            XCTAssertNotEqual(try Data(contentsOf: item.file.url), uploadGIFTimingFixture)
            let document = try XCTUnwrap(item.presented(as: .file))
            XCTAssertEqual(document.file.id, raw.id); XCTAssertEqual(document.file.url, raw.url)
            XCTAssertEqual(document.file.metadata, metadata); XCTAssertNil(document.file.video)
            XCTAssertEqual(item.presented(as: .media)?.file, item.file)
            XCTAssertEqual(controller.captionInput.formattedText.text, "GIF 😀")
        }
    }

    // Catches unsafe recognizable GIF falling through into the photo or audio decoder.
    func testUnsafeGIFRemainsUnchangedGenericFile() async throws {
        let bytes = Data("GIF89a".utf8) + Data(repeating: 0, count: 10)
        let url = try source(bytes, name: "misleading.jpg")
        let controller = TelegramUploadController(); defer { controller.clear() }
        controller.bind(provider: TelegramSyntheticUploadProvider())
        controller.prepare(sources: [.init(source: url, mode: .photo)], isGrouped: false,
            target: .init(accountID: -1, chatID: 42, title: "Synthetic unsafe GIF"),
            captionInput: try .init(formattedText: .init(text: "")))
        for _ in 0..<1000 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready)
        let item = try XCTUnwrap(controller.items.first)
        XCTAssertEqual(item.file.mode, .file); XCTAssertNil(item.file.metadata); XCTAssertNil(item.originalFile)
        XCTAssertEqual(try Data(contentsOf: item.file.url), bytes)
    }

    // Catches treating known GIF bytes under .wav as music or allowing typed WebP in a group.
    func testGroupingUsesFrozenGIFKindInsteadOfMisleadingSuffix() {
        let gif = (name: "opaque.wav", isVisual: true, metadata: Optional(metadata))
        let photo = (name: "photo.jpg", isVisual: true, metadata: Optional<TelegramUploadMetadata>.none)
        let music = (name: "music.bin", isVisual: false,
            metadata: Optional(TelegramUploadMetadata.audio(.init(duration: 1, title: "", performer: ""))))
        let webp = (name: "picture.bin", isVisual: false,
            metadata: Optional(TelegramUploadMetadata.webP(.init(width: 32, height: 16))))
        for presentation: TelegramUploadPresentation in [.file, .media] {
            XCTAssertTrue(presentation.allowsGrouping([gif, gif]))
            XCTAssertTrue(presentation.allowsGrouping([gif, photo]))
            XCTAssertFalse(presentation.allowsGrouping([gif, music]))
            XCTAssertFalse(presentation.allowsGrouping([gif, webp]))
        }
    }

    // Catches positive measured duration/streaming leaking into GIF's wire0 or raw GIF carrying Video.
    func testBothProjectionsUseExactGIFNativeAttributesAndCanonicalMIME() throws {
        initializeAccountManagement()
        let raw = TelegramUploadFile(id: UUID(), name: "opaque.wav", size: 200, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: URL(fileURLWithPath: "/unused/raw"), directory: URL(fileURLWithPath: "/unused"))
        for inCollage in [true, false] {
            let canonical = TelegramUploadFile(id: UUID(), name: "opaque.mp4", size: 2048, mode: .video,
                pixelWidth: 32, pixelHeight: 16, url: URL(fileURLWithPath: "/unused/mp4"), directory: URL(fileURLWithPath: "/unused"),
                video: .init(width: 32, height: 16, duration: 0.75, hasAudio: false, inCollage: inCollage), metadata: metadata)
            let item = TelegramUploadBatchItem(id: UUID(), file: canonical, originalFile: raw)
            let media = try XCTUnwrap(telegramUploadMedia(canonical)?.1.media as? TelegramMediaFile)
            var expected: [TelegramMediaFileAttribute] = [.Video(duration: 0, size: .init(width: 32, height: 16),
                flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil)]
            if !inCollage { expected.append(.Animated) }
            expected.append(.FileName(fileName: "opaque.mp4"))
            XCTAssertEqual(media.attributes, expected); XCTAssertEqual(media.mimeType, "video/mp4")
            XCTAssertTrue(media.previewRepresentations.isEmpty); XCTAssertTrue(media.videoThumbnails.isEmpty)
            XCTAssertNil(media.videoCover); XCTAssertNil(media.immediateThumbnailData)
            let projected = try XCTUnwrap(item.presented(as: .file))
            let document = try XCTUnwrap(telegramUploadMedia(projected.file)?.1.media as? TelegramMediaFile)
            XCTAssertEqual(document.mimeType, "image/gif")
            XCTAssertEqual(document.attributes, [.ImageSize(size: .init(width: 32, height: 16)), .FileName(fileName: "opaque.wav")])
            XCTAssertEqual(document.size, 200)
            XCTAssertFalse(document.isVideo); XCTAssertFalse(document.isAnimated)
        }
    }

    // Catches discarding GIF provenance on native MP4 restore or accepting a changed source canvas.
    func testOwnedRawAndCanonicalMetadataAreReprobedAndRetainedOnRestore() async throws {
        let raw = try await TelegramUploadFileIO.stage(source(uploadGIFTimingFixture, name: "opaque.bin"), mode: .file)
        defer { try? TelegramUploadFileIO.discard(raw) }
        let converted = try await TelegramUploadGIFIO.convert(raw,
            expected: .init(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.4]))
        defer { try? TelegramUploadFileIO.discard(converted) }
        let canonical = TelegramUploadFile(id: converted.id, name: converted.name, size: converted.size, mode: .video,
            pixelWidth: 32, pixelHeight: 16, url: converted.url, directory: converted.directory,
            video: converted.video, metadata: metadata)
        let document = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory, metadata: metadata)
        try TelegramUploadFileIO.validateMetadata(canonical)
        try TelegramUploadFileIO.validateMetadata(document)
        try await TelegramUploadFileIO.verifyMetadata(document)
        let restored = try await TelegramUploadFileIO.restoredStage(id: canonical.id, name: canonical.name,
            size: canonical.size, mode: .video, url: canonical.url, directory: canonical.directory,
            video: canonical.video, metadata: metadata)
        XCTAssertEqual(restored, canonical)
        let bad = TelegramUploadFile(id: canonical.id, name: canonical.name, size: canonical.size, mode: .video,
            pixelWidth: 32, pixelHeight: 16, url: canonical.url, directory: canonical.directory, video: canonical.video,
            metadata: .gif(.init(width: 31, height: 16, frameDurations: [0.05, 0.2, 0.4], sourceSHA256: metadata.gif!.sourceSHA256)))
        XCTAssertThrowsError(try TelegramUploadFileIO.validateMetadata(bad))
    }
}

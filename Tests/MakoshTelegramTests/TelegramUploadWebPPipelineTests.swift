import XCTest
import Foundation
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramUploadWebPPipelineTests: XCTestCase {
    // Catches losing original bytes or overriding selected image MIME with the decoder's WebP type.
    @MainActor func testControllerUsesSelectedPhotoMIMEAndRetainsWebPOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = TelegramUploadMetadata.webP(.init(width: 320, height: 160))
        for fixture in [UploadWebPFixture.staticLossless, .animated, .partialCanvas] {
            for (name, mode): (String, TelegramUploadMode) in [("Picture.webp", .file), ("Picture.jpg", .photo), ("Picture.wav", .file), ("Picture.bin", .file)] {
                let source = root.appendingPathComponent(name)
                try writeUploadWebPFixture(source, fixture: fixture)
                let controller = TelegramUploadController()
                controller.bind(provider: TelegramSyntheticUploadProvider())
                controller.prepare(sources: [.init(source: source, mode: mode)], isGrouped: true,
                    target: .init(accountID: -1, chatID: 42, title: "Synthetic WebP"),
                    captionInput: try TelegramComposerInput(formattedText: TelegramFormattedText(text: "WebP 😀")))
                for _ in 0..<1000 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(controller.phase, .ready)
                let item = try XCTUnwrap(controller.items.first)
                if name == "Picture.jpg" {
                    XCTAssertEqual(item.file.mode, .photo); XCTAssertNil(item.file.metadata)
                    XCTAssertEqual(item.file.pixelWidth, 320); XCTAssertEqual(item.file.pixelHeight, 160)
                    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(item.originalFile).url), fixture.data)
                    XCTAssertTrue(controller.canGroupItems); XCTAssertTrue(controller.isGrouped)
                } else {
                    XCTAssertEqual(item.file.metadata, expected); XCTAssertEqual(item.file.mode, .file)
                    XCTAssertEqual(item.file.name, name); XCTAssertNil(item.originalFile)
                    XCTAssertEqual(try Data(contentsOf: item.file.url), fixture.data)
                    XCTAssertFalse(controller.canGroupItems); XCTAssertFalse(controller.isGrouped)
                }
                XCTAssertEqual(controller.presentation, name == "Picture.jpg" ? .media : .file)
                XCTAssertEqual(controller.canSwitchPresentation, name == "Picture.jpg")
                controller.clear()
            }
        }
    }

    // Recognizable but unsafe data must not be reinterpreted as photo/audio after probe refusal.
    @MainActor func testControllerRetainsUnsafeWebPAsUnchangedGenericFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = UploadWebPFixture.staticLossless.data + Data([0])
        let source = root.appendingPathComponent("Misleading.jpg"); try bytes.write(to: source)
        let controller = TelegramUploadController(); defer { controller.clear() }
        controller.bind(provider: TelegramSyntheticUploadProvider())
        controller.prepare(sources: [.init(source: source, mode: .photo)], isGrouped: false,
            target: .init(accountID: -1, chatID: 42, title: "Synthetic unsafe WebP"),
            captionInput: try TelegramComposerInput(formattedText: TelegramFormattedText(text: "")))
        for _ in 0..<1000 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready)
        let item = try XCTUnwrap(controller.items.first)
        XCTAssertNil(item.file.metadata); XCTAssertNil(item.originalFile); XCTAssertEqual(item.file.mode, .file)
        XCTAssertEqual(try Data(contentsOf: item.file.url), bytes)
    }

    private func metadata(width: Int = 48, height: Int = 32) throws -> TelegramUploadMetadata {
        let data = try JSONSerialization.data(withJSONObject: ["kind": "webp", "payload": ["width": width, "height": height]])
        return try JSONDecoder().decode(TelegramUploadMetadata.self, from: data)
    }

    private func json(version: Int = 9) throws -> [String: Any] {
        var value = try pendingUploadBatchJSON(), items = value["items"] as! [[String: Any]]
        items[0]["metadata"] = ["kind": "webp", "payload": ["width": 48, "height": 32]]
        value["items"] = items; value["schemaVersion"] = version; value["isGrouped"] = false
        if version >= 8 { value["presentation"] = "file" }
        return value
    }

    private func decode(_ json: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func file(name: String = "picture.bin", mode: TelegramUploadMode = .file,
                      metadata: TelegramUploadMetadata?) -> TelegramUploadFile {
        .init(id: UUID(), name: name, size: 42, mode: mode, pixelWidth: nil, pixelHeight: nil,
            url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"), metadata: metadata)
    }

    func testSchema9RetainsWebPDimensionsWithOriginalFileAndExplicitMode() throws {
        let draft: TelegramPendingUploadDraft
        do { draft = try decode(json()) }
        catch { return XCTFail("Schema9 must admit strict WebP dimensions: \(error)") }
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.items[0].metadata, try metadata())
        XCTAssertNil(draft.items[0].originalFile); XCTAssertNil(draft.items[1].metadata)
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONEncoder().encode(draft)), draft)
        let constructed = try TelegramPendingUploadDraft(id: draft.id, accountID: draft.accountID, chatID: draft.chatID,
            title: draft.title, captionInput: draft.captionInput, originalDraft: nil, replyTarget: nil,
            items: draft.items, isGrouped: false, presentation: .file)
        XCTAssertEqual(constructed.schemaVersion, 9); XCTAssertTrue(constructed.isValid)
        for version in [6, 7, 8] {
            do { let older = try decode(json(version: version)); XCTAssertFalse(older.isValid) }
            catch is DecodingError {}
        }
    }

    func testStrictWebPCodecRefusesNullMissingExtraAndCrossKindDimensions() throws {
        do { _ = try metadata() }
        catch { return XCTFail("Valid WebP must decode before testing refusal: \(error)") }
        let invalid: [[String: Any]] = [
            ["kind": "webp", "payload": NSNull()],
            ["kind": "webp", "payload": ["width": 48]],
            ["kind": "webp", "payload": ["width": 48, "height": 32, "duration": 1]],
            ["kind": "webp", "payload": ["width": 48, "height": 32], "voice": false],
            ["kind": "audio", "payload": ["width": 48, "height": 32]],
            ["kind": "webp", "payload": ["duration": 1, "title": "", "performer": ""]]
        ]
        for value in invalid {
            let data = try JSONSerialization.data(withJSONObject: value)
            XCTAssertThrowsError(try JSONDecoder().decode(TelegramUploadMetadata.self, from: data))
        }
        for (width, height) in [(0, 1), (1, -1), (8193, 1), (8192, 8192)] {
            XCTAssertThrowsError(try metadata(width: width, height: height))
        }
    }

    func testBothPresentationsRetainWebPBytesAndExactNativeStickerAttributesRegardlessOfName() throws {
        let descriptor: TelegramUploadMetadata
        do { descriptor = try metadata() }
        catch { return XCTFail("WebP descriptor missing: \(error)") }
        initializeAccountManagement()
        for name in ["picture.webp", "picture.jpg", "picture.wav", "picture.bin"] {
            let source = file(name: name, metadata: descriptor), item = TelegramUploadBatchItem(id: UUID(), file: source)
            for mode: TelegramUploadPresentation in [.file, .media] {
                let projected = try XCTUnwrap(item.presented(as: mode))
                XCTAssertEqual(projected.file.metadata, descriptor); XCTAssertEqual(projected.file.url, source.url)
                XCTAssertEqual(projected.file.size, source.size); XCTAssertEqual(projected.file.id, source.id)
                let media = try XCTUnwrap(telegramUploadMedia(projected.file)?.1.media as? TelegramMediaFile)
                let attributes: [TelegramMediaFileAttribute] = [
                    .ImageSize(size: PixelDimensions(width: 48, height: 32)), .FileName(fileName: name),
                    .Sticker(displayText: "", packReference: nil, maskData: nil)
                ]
                XCTAssertEqual(media.attributes, attributes); XCTAssertEqual(media.mimeType, "image/webp")
                let encoder = PostboxEncoder(); encoder.encodeRootObject(media)
                let decoded = try XCTUnwrap(PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())).decodeRootObject() as? TelegramMediaFile)
                XCTAssertEqual(decoded.attributes, attributes); XCTAssertEqual(decoded.mimeType, "image/webp")
            }
        }
    }

    func testTypedWebPNeverGroupsWithItselfOrMusicEvenUnderMisleadingSuffix() throws {
        let descriptor: TelegramUploadMetadata
        do { descriptor = try metadata() }
        catch { return XCTFail("WebP descriptor missing: \(error)") }
        let webp = (name: "picture.bin", isVisual: false, metadata: Optional(descriptor))
        let audio = (name: "music.bin", isVisual: false,
                     metadata: Optional(TelegramUploadMetadata.audio(.init(duration: 1, title: "", performer: ""))))
        for presentation: TelegramUploadPresentation in [.file, .media] {
            XCTAssertFalse(presentation.allowsGrouping([webp]))
            XCTAssertFalse(presentation.allowsGrouping([webp, webp]))
            XCTAssertFalse(presentation.allowsGrouping([webp, audio]))
            XCTAssertFalse(presentation.allowsGrouping([audio, webp]))
        }
        var value = try json(); value["isGrouped"] = true
        XCTAssertFalse(try decode(value).isValid)
    }

    func testTypedWebPCannotBecomePhotoVideoOrLegacyNameInferredSticker() throws {
        let descriptor: TelegramUploadMetadata
        do { descriptor = try metadata() }
        catch { return XCTFail("WebP descriptor missing: \(error)") }
        for mode: TelegramUploadMode in [.photo, .video] { XCTAssertNil(telegramUploadMedia(file(mode: mode, metadata: descriptor))) }
        let legacy = telegramUploadMedia(file(name: "legacy.webp", metadata: nil))?.1.media as? TelegramMediaFile
        XCTAssertEqual(legacy?.attributes, [.FileName(fileName: "legacy.webp")])
        for key in ["video", "videoCover", "originalFile"] {
            var value = try json(), items = value["items"] as! [[String: Any]]
            items[0][key] = NSNull(); value["items"] = items
            XCTAssertThrowsError(try decode(value))
        }
    }

    func testNativeReceiptRefusesDroppedOrChangedWebP() throws {
        let prepared: TelegramPendingUploadDraft
        do { prepared = try decode(json()) }
        catch { return XCTFail("WebP preparation missing: \(error)") }
        let draft = prepared.updating(captionInput: prepared.captionInput, captionAboveMedia: false,
            mediaSpoiler: false, disposition: .submissionStarted)
        func resources(first: TelegramUploadMetadata?) throws -> [TelegramUploadBatchResource] {
            try draft.items.enumerated().map { index, stored in
                let file = file(name: stored.file.attachment.name, metadata: index == 0 ? first : nil)
                let staged = TelegramUploadFile(id: file.id, name: file.name, size: stored.file.plaintextByteCount,
                    mode: .file, pixelWidth: nil, pixelHeight: nil, url: file.url, directory: file.directory, metadata: file.metadata)
                let mapped = try XCTUnwrap(telegramUploadMedia(staged))
                return .init(item: .init(id: stored.id, file: staged), plaintextSHA256: stored.file.plaintextSHA256,
                    prepared: .init(resource: mapped.0, reference: mapped.1, videoThumbnail: nil))
            }
        }
        let target = TelegramUploadTarget(accountID: draft.accountID, chatID: draft.chatID, title: draft.title)
        XCTAssertNoThrow(try TelegramUploadBatchEnqueueReceipt(draft: draft, target: target, resources: resources(first: metadata()), groupKeys: []))
        for altered in [nil, try metadata(width: 49), TelegramUploadMetadata.audio(.init(duration: 1, title: "", performer: ""))] {
            XCTAssertThrowsError(try TelegramUploadBatchEnqueueReceipt(draft: draft, target: target, resources: resources(first: altered), groupKeys: []))
        }
    }
}

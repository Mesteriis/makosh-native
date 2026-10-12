import XCTest
import Foundation
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramUploadAudioPipelineTests: XCTestCase {
    private let audio = TelegramUploadMetadata.audio(.init(duration: 1, title: "Synthetic 😀", performer: "Artist"))

    private func file(mode: TelegramUploadMode = .file, metadata: TelegramUploadMetadata? = nil) -> TelegramUploadFile {
        .init(id: UUID(), name: "track.wav", size: 42, mode: mode, pixelWidth: nil, pixelHeight: nil,
            url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"), metadata: metadata)
    }

    private func json(version: Int = 9) throws -> [String: Any] {
        var json = try pendingUploadBatchJSON(), items = json["items"] as! [[String: Any]]
        items[0]["metadata"] = ["kind": "audio", "payload": ["duration": 1, "title": "Synthetic 😀", "performer": "Artist"]]
        json["items"] = items; json["schemaVersion"] = version; json["isGrouped"] = false
        if version >= 8 { json["presentation"] = "file" }
        return json
    }

    private func decode(_ json: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSchema9RetainsTypedAudioWithEveryOrderedResourceAndExplicitMode() throws {
        let draft: TelegramPendingUploadDraft
        do { draft = try decode(json()) }
        catch { return XCTFail("Schema9 must retain typed audio and ordered resources: \(error)") }
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.items[0].metadata, audio)
        XCTAssertNil(draft.items[1].metadata); XCTAssertEqual(draft.presentation, .file)
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONEncoder().encode(draft)), draft)
        let constructed = try TelegramPendingUploadDraft(id: draft.id, accountID: draft.accountID, chatID: draft.chatID,
            title: draft.title, captionInput: draft.captionInput, originalDraft: nil, replyTarget: nil,
            items: draft.items, isGrouped: false, presentation: .file)
        XCTAssertEqual(constructed.schemaVersion, 9); XCTAssertTrue(constructed.isValid)
    }

    func testOlderSchemasCannotHideTypedAudio() throws {
        for version in [6, 7, 8] {
            do { let draft = try decode(json(version: version)); XCTAssertFalse(draft.isValid, "Older schema \(version) must refuse typed attributes") }
            catch is DecodingError {}
        }
    }

    func testSchema9RefusesMissingNullUnknownAndCrossKindMetadata() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0.removeValue(forKey: "presentation") },
            { var items = $0["items"] as! [[String: Any]]; items[0].removeValue(forKey: "metadata"); $0["items"] = items },
            { var items = $0["items"] as! [[String: Any]]; items[0]["metadata"] = NSNull(); $0["items"] = items },
            { var items = $0["items"] as! [[String: Any]]; items[0]["metadata"] = ["kind": "voice", "payload": ["duration": 1]]; $0["items"] = items },
            { var items = $0["items"] as! [[String: Any]], f = items[0]["file"] as! [String: Any], a = f["attachment"] as! [String: Any]; a["kind"] = "photo"; f["attachment"] = a; items[0]["file"] = f; $0["items"] = items }
        ]
        for mutate in mutations {
            var value = try json(); mutate(&value)
            do { let draft = try decode(value); XCTAssertFalse(draft.isValid) } catch is DecodingError {}
        }
        // Explicit null must fail even when another item makes the schema otherwise valid.
        var value = try json(), items = value["items"] as! [[String: Any]]
        items[1]["metadata"] = NSNull(); value["items"] = items
        XCTAssertThrowsError(try decode(value))
    }

    func testTypedAudioCannotHideConflictingNullResourceFields() throws {
        for key in ["video", "videoCover", "originalFile"] {
            var value = try json(), items = value["items"] as! [[String: Any]]
            items[0][key] = NSNull(); value["items"] = items
            XCTAssertThrowsError(try decode(value), "Typed audio has no \(key), including explicit null")
        }
    }

    func testFileProjectionPreservesMusicAttributesAndOriginalBytesIdentity() throws {
        let source = file(metadata: audio), item = TelegramUploadBatchItem(id: UUID(), file: source)
        for mode: TelegramUploadPresentation in [.file, .media] {
            let projected = try XCTUnwrap(item.presented(as: mode))
            XCTAssertEqual(projected.file.metadata, audio)
            XCTAssertEqual(projected.file.url, source.url); XCTAssertEqual(projected.file.id, source.id)
            XCTAssertEqual(projected.file.size, source.size); XCTAssertNil(projected.file.video)
        }
    }

    func testNativeMusicAttributesSurvivePostboxWithoutVoiceOrWaveform() throws {
        initializeAccountManagement()
        for descriptor in [audio, .audio(.init(duration: 0, title: "", performer: ""))] {
            let media = try XCTUnwrap(telegramUploadMedia(file(metadata: descriptor))?.1.media as? TelegramMediaFile)
            guard case let .audio(value) = descriptor else { return XCTFail("Fixture must be ordinary music") }
            let expected: [TelegramMediaFileAttribute] = [
                .Audio(isVoice: false, duration: Int(value.duration), title: value.title, performer: value.performer, waveform: nil),
                .FileName(fileName: "track.wav")
            ]
            XCTAssertEqual(media.attributes, expected)
            let encoder = PostboxEncoder(); encoder.encodeRootObject(media)
            let decoded = try XCTUnwrap(PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())).decodeRootObject() as? TelegramMediaFile)
            XCTAssertEqual(decoded.attributes, expected)
        }
    }

    func testInvalidAudioCannotBecomeNativeMediaOrAttachToPhoto() {
        XCTAssertNil(telegramUploadMedia(file(metadata: .audio(.init(duration: -1, title: "", performer: "")))))
        XCTAssertNil(telegramUploadMedia(file(mode: .photo, metadata: audio)))
        let plain = telegramUploadMedia(file())?.1.media as? TelegramMediaFile
        XCTAssertEqual(plain?.attributes, [.FileName(fileName: "track.wav")], "Legacy generic files must not gain attributes from a suffix")
    }

    func testTypedMusicGroupingRequiresEveryItemToHaveProbedMusicMetadata() throws {
        var value = try json(), items = value["items"] as! [[String: Any]]
        for index in items.indices {
            var file = items[index]["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
            attachment["name"] = "track-\(index).wav"; file["attachment"] = attachment; items[index]["file"] = file
        }
        value["items"] = items; value["isGrouped"] = true
        XCTAssertFalse(try decode(value).isValid, "A suffix cannot turn an unprobed generic file into a music album")
        items[1]["metadata"] = items[0]["metadata"]; value["items"] = items
        XCTAssertTrue(try decode(value).isValid, "A complete ordinary music album remains groupable")
    }

    func testBatchReceiptRefusesDroppedOrChangedTypedAudioMetadata() throws {
        let prepared = try decode(json())
        let draft = prepared.updating(captionInput: prepared.captionInput, captionAboveMedia: false,
            mediaSpoiler: false, disposition: .submissionStarted)
        func resources(first: TelegramUploadMetadata?) throws -> [TelegramUploadBatchResource] {
            try draft.items.enumerated().map { index, stored in
                let file = TelegramUploadFile(id: UUID(), name: stored.file.attachment.name,
                    size: stored.file.plaintextByteCount, mode: .file, pixelWidth: nil, pixelHeight: nil,
                    url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"),
                    metadata: index == 0 ? first : nil)
                let mapped = try XCTUnwrap(telegramUploadMedia(file))
                return .init(item: .init(id: stored.id, file: file), plaintextSHA256: stored.file.plaintextSHA256,
                    prepared: .init(resource: mapped.0, reference: mapped.1, videoThumbnail: nil))
            }
        }
        let target = TelegramUploadTarget(accountID: draft.accountID, chatID: draft.chatID, title: draft.title)
        XCTAssertNoThrow(try TelegramUploadBatchEnqueueReceipt(draft: draft, target: target, resources: resources(first: audio), groupKeys: []))
        for altered in [nil, TelegramUploadMetadata.audio(.init(duration: 2, title: "Synthetic 😀", performer: "Artist"))] {
            XCTAssertThrowsError(try TelegramUploadBatchEnqueueReceipt(draft: draft, target: target,
                resources: resources(first: altered), groupKeys: []))
        }
    }

    func testRestoreReprobesFrozenAudioInsteadOfReplacingItsDescriptor() async throws {
        let raw = try await Self.stageAudio()
        defer { try? TelegramUploadFileIO.discard(raw) }
        let expected = TelegramUploadMetadata.audio(.init(duration: 1, title: "", performer: ""))
        let restored = try await TelegramUploadFileIO.restoredStage(id: raw.id, name: raw.name, size: raw.size,
            mode: .file, url: raw.url, directory: raw.directory, metadata: expected)
        XCTAssertEqual(restored.metadata, expected)
        for wrong in [TelegramUploadMetadata.audio(.init(duration: 2, title: "", performer: "")),
                      .audio(.init(duration: 1, title: "Replaced", performer: "")),
                      .audio(.init(duration: 1, title: "", performer: "Replaced"))] {
            do {
                _ = try await TelegramUploadFileIO.restoredStage(id: raw.id, name: raw.name, size: raw.size,
                    mode: .file, url: raw.url, directory: raw.directory, metadata: wrong)
                XCTFail("Frozen duration/tags cannot be replaced by a new probe")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidAudio) }
        }
    }

    @MainActor func testFilePickerPreparesOrdinaryMusicWithoutInferringVoice() async throws {
        let raw = try await Self.stageAudio(), controller = TelegramUploadController()
        defer { try? TelegramUploadFileIO.discard(raw); controller.clear() }
        controller.bind(provider: AudioPipelineProvider())
        // The picker has only a name/MIME hint; facts come from our owned snapshot.
        let named = raw.directory.appendingPathComponent("Synthetic.wav")
        try Data(contentsOf: raw.url).write(to: named)
        defer { try? FileManager.default.removeItem(at: named) }
        controller.prepare(sources: [.init(source: named, mode: .file)], isGrouped: false,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.file?.mode, .file); XCTAssertEqual(controller.presentation, .file)
        XCTAssertEqual(controller.file?.metadata, .audio(.init(duration: 1, title: "", performer: "")))
        XCTAssertEqual(controller.items.first?.file.metadata, controller.file?.metadata)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(controller.items.first?.file.url)), try Data(contentsOf: raw.url))
    }

    private static func stageAudio() async throws -> TelegramUploadFile {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Synthetic.wav")
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(20_036); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(8_000); u32(16_000); u16(2); u16(16); text("data"); u32(20_000)
        data.append(Data(repeating: 0, count: 20_000)); try data.write(to: source)
        return try await TelegramUploadFileIO.stage(source, mode: .file)
    }
}

@MainActor private final class AudioPipelineProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Preparation must not send"); return AudioPipelineLease()
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
                captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Preparation must not send"); return AudioPipelineLease()
    }
}
@MainActor private final class AudioPipelineLease: TelegramUploadLease { func stop() {} }

import XCTest
import Foundation
import AVFoundation
@testable import MakoshTelegram

final class TelegramUploadAudioIOTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func stage(seconds: Double = 1.25, name: String = "opaque.bin") async throws -> (TelegramUploadFile, Data) {
        let source = try directory().appendingPathComponent(name)
        try writeUploadAudioFixture(source, seconds: seconds)
        let bytes = try Data(contentsOf: source)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(raw) }
        try FileManager.default.removeItem(at: source)
        return (raw, bytes)
    }

    // Catches filename-only admission, fractional duration rounding, filename tag fallback and rewrites.
    func testPCMOwnedBytesUseIntegralDurationAndPreserveEmptyTagsAndBytes() async throws {
        let (raw, bytes) = try await stage(name: "Performer-Title.ogg")
        let metadata = try await TelegramUploadAudioIO.inspect(raw)
        XCTAssertEqual(metadata.duration, 1)
        XCTAssertEqual(metadata.title, ""); XCTAssertEqual(metadata.performer, "")
        XCTAssertTrue(metadata.isValid)
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
        XCTAssertEqual(raw.name, "Performer-Title.ogg")
    }

    // Positive duration below one second legitimately truncates to native zero seconds.
    func testSubsecondAudioKeepsZeroIntegralDuration() async throws {
        let (raw, _) = try await stage(seconds: 0.25)
        let metadata = try await TelegramUploadAudioIO.inspect(raw)
        XCTAssertEqual(metadata.duration, 0); XCTAssertTrue(metadata.isValid)
    }

    // Exercises actual macOS AAC metadata, preserving meaningful whitespace rather than filename inference.
    func testTaggedM4AReadsOriginalTitleAndPerformer() async throws {
        let source = try directory().appendingPathComponent("Wrong-Name.m4a")
        try await writeUploadTaggedAudioFixture(source, title: " Synthetic Title ", performer: "Synthetic Artist")
        let bytes = try Data(contentsOf: source), raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(raw) }
        try FileManager.default.removeItem(at: source)
        let metadata = try await TelegramUploadAudioIO.inspect(raw)
        XCTAssertEqual(metadata.duration, 1)
        XCTAssertEqual(metadata.title, " Synthetic Title "); XCTAssertEqual(metadata.performer, "Synthetic Artist")
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    // Actual MPEG audio with ID3, independently generated and embedded; no encoder is required at test time.
    func testGoldenMP3ReadsNativeTagsAndDurationWithoutFilenameInference() async throws {
        let source = try directory().appendingPathComponent("Unrelated.bin")
        try writeUploadMP3AudioFixture(source)
        let bytes = try Data(contentsOf: source), raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(raw) }
        try FileManager.default.removeItem(at: source)
        let metadata = try await TelegramUploadAudioIO.inspect(raw)
        XCTAssertEqual(metadata.duration, 1)
        XCTAssertEqual(metadata.title, "Synthetic MP3"); XCTAssertEqual(metadata.performer, "Synthetic Artist")
        XCTAssertTrue(metadata.isValid)
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    // Catches out-of-range/native-invalid persisted metadata and UTF8 rather than character bounds.
    func testMetadataValidationAndCodableRejectInvalidNativeValues() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        for value in [
            TelegramUploadAudioMetadata(duration: 0, title: "", performer: ""),
            .init(duration: 604_800, title: String(repeating: "é", count: 2_048), performer: "Artist")
        ] {
            XCTAssertTrue(value.isValid)
            XCTAssertEqual(try decoder.decode(TelegramUploadAudioMetadata.self, from: encoder.encode(value)), value)
        }
        for value in [
            TelegramUploadAudioMetadata(duration: -1, title: "", performer: ""),
            .init(duration: 604_801, title: "", performer: ""),
            .init(duration: 1, title: String(repeating: "é", count: 2_049), performer: ""),
            .init(duration: 1, title: "", performer: String(repeating: "x", count: 4_097)),
            .init(duration: 1, title: "a\0b", performer: ""),
            .init(duration: 1, title: "", performer: "a\0b")
        ] {
            XCTAssertFalse(value.isValid)
            XCTAssertThrowsError(try encoder.encode(value))
        }
        for json in [
            #"{"duration":-1,"title":"","performer":""}"#,
            #"{"duration":604801,"title":"","performer":""}"#,
            #"{"duration":1.25,"title":"","performer":""}"#,
            #"{"duration":1,"title":null,"performer":""}"#,
            #"{"duration":1,"title":""}"#,
            #"{"duration":1,"title":"","performer":"","isVoice":true}"#
        ] { XCTAssertThrowsError(try decoder.decode(TelegramUploadAudioMetadata.self, from: Data(json.utf8))) }
    }

    // Catches a union decoder accepting unknown, cross-kind, null, absent or undeclared payload fields.
    func testDiscriminatedUnionUsesStrictKindAndPayload() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let valid = Data(#"{"kind":"audio","payload":{"duration":1,"title":"","performer":""}}"#.utf8)
        let value = TelegramUploadMetadata.audio(.init(duration: 1, title: "", performer: ""))
        XCTAssertEqual(try decoder.decode(TelegramUploadMetadata.self, from: valid), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "payload"])
        XCTAssertEqual(object["kind"] as? String, "audio")
        for json in [
            #"{"kind":"voice","payload":{"duration":1,"title":"","performer":""}}"#,
            #"{"kind":"audio"}"#,
            #"{"payload":{"duration":1,"title":"","performer":""}}"#,
            #"{"kind":"audio","payload":null}"#,
            #"{"kind":null,"payload":{"duration":1,"title":"","performer":""}}"#,
            #"{"kind":"audio","payload":{"width":40,"height":40,"duration":1}}"#,
            #"{"kind":"audio","payload":{"duration":1,"title":"","performer":""},"video":{}}"#
        ] { XCTAssertThrowsError(try decoder.decode(TelegramUploadMetadata.self, from: Data(json.utf8))) }
    }

    // Invalid audio bytes must not receive plausible duration/tags merely from a suffix.
    func testUndecodableBytesFailAsInvalidAudio() async throws {
        let source = try directory().appendingPathComponent("claimed.wav")
        try Data("synthetic text".utf8).write(to: source)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(raw) }
        do { _ = try await TelegramUploadAudioIO.inspect(raw); XCTFail("Undecodable bytes must be refused") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidAudio) }
    }

    // Catches accepting arbitrary URLs or a non-file mode as owned raw audio.
    func testNonOwnedAndNonFileStagesFailClosed() async throws {
        let source = try directory().appendingPathComponent("outside.wav")
        try writeUploadAudioFixture(source)
        let fake = TelegramUploadFile(id: UUID(), name: "outside.wav", size: Int64(try Data(contentsOf: source).count),
            mode: .file, pixelWidth: nil, pixelHeight: nil, url: source, directory: source.deletingLastPathComponent())
        do { _ = try await TelegramUploadAudioIO.inspect(fake); XCTFail("Non-owned URLs must be refused") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        let (raw, _) = try await stage()
        let photo = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .photo,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory)
        do { _ = try await TelegramUploadAudioIO.inspect(photo); XCTFail("Only raw file mode is admitted") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }

    // Catches following a replaced symlink or trusting the stale staged byte count.
    func testChangedOwnedStageAndSymlinkAreRefused() async throws {
        let (changed, bytes) = try await stage()
        try (bytes + Data([0])).write(to: changed.url)
        do { _ = try await TelegramUploadAudioIO.inspect(changed); XCTFail("Changed size must be refused") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        let (linked, original) = try await stage()
        let outside = try directory().appendingPathComponent("outside.wav")
        try original.write(to: outside)
        try FileManager.default.removeItem(at: linked.url)
        try FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: outside)
        do { _ = try await TelegramUploadAudioIO.inspect(linked); XCTFail("Symlink must be refused") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    // Cancellation is control flow, never an unsupported-codec result.
    func testCancellationIsNotReportedAsInvalidAudio() async throws {
        let (raw, _) = try await stage()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramUploadAudioIO.inspect(raw)
        }
        do { _ = try await task.value; XCTFail("Cancellation must throw") } catch is CancellationError {}
    }
}

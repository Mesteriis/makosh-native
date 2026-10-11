import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramUploadWebPIOTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func stage(_ bytes: Data, name: String = "opaque.bin") async throws -> TelegramUploadFile {
        let source = try directory().appendingPathComponent(name)
        try bytes.write(to: source)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(raw) }
        try FileManager.default.removeItem(at: source)
        return raw
    }

    private func invalidWebP(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) async throws {
        let raw = try await stage(bytes)
        do { _ = try await TelegramUploadWebPIO.inspect(raw); XCTFail("Recognizable unsafe WebP must throw", file: file, line: line) }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidWebP, file: file, line: line) }
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes, file: file, line: line)
    }

    // Catches wrong-axis/product bounds, a photo40pt rule leaking into sticker metadata, and overflow.
    func testMetadataNativeBoundsAndStrictJSON() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        for value in [TelegramUploadWebPMetadata(width: 320, height: 160), .init(width: 1, height: 1),
                      .init(width: 8192, height: 1), .init(width: 8000, height: 5000)] {
            XCTAssertTrue(value.isValid)
            XCTAssertEqual(try decoder.decode(TelegramUploadWebPMetadata.self, from: encoder.encode(value)), value)
        }
        let valid = try decoder.decode(TelegramUploadWebPMetadata.self, from: Data(#"{"width":320,"height":160}"#.utf8))
        XCTAssertEqual(valid, .init(width: 320, height: 160))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(valid)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["width", "height"])
        for value in [TelegramUploadWebPMetadata(width: 0, height: 160), .init(width: 320, height: 0),
                      .init(width: -1, height: 1), .init(width: 1, height: -1),
                      .init(width: 8193, height: 1), .init(width: 1, height: 8193),
                      .init(width: 8000, height: 5001), .init(width: .max, height: .max)] {
            XCTAssertFalse(value.isValid); XCTAssertThrowsError(try encoder.encode(value))
        }
        for invalid in [
            #"{"width":0,"height":160}"#, #"{"width":320,"height":0}"#,
            #"{"width":8000,"height":5001}"#, #"{"width":8193,"height":40}"#,
            #"{"width":320.5,"height":160}"#, #"{"width":true,"height":160}"#,
            #"{"width":2147483648,"height":160}"#, #"{"width":320}"#,
            #"{"width":null,"height":160}"#, #"{"width":320,"height":null}"#,
            #"{"width":320,"height":160,"animated":true}"#
        ] { XCTAssertThrowsError(try decoder.decode(TelegramUploadWebPMetadata.self, from: Data(invalid.utf8))) }
    }

    // Catches filename-based admission, photo normalization and trusting already-persisted metadata.
    func testStaticLosslessProbesOwnedOpaqueBytesAndIgnoresExpectedMetadata() async throws {
        let bytes = UploadWebPFixture.staticLossless.data
        let raw = try await stage(bytes, name: "Misleading.jpg")
        let typed = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory,
            metadata: .audio(.init(duration: 1, title: "", performer: "")))
        let value = try await TelegramUploadWebPIO.inspect(typed)
        XCTAssertEqual(value, .init(width: 320, height: 160))
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
        XCTAssertEqual(raw.name, "Misleading.jpg")
    }

    // Catches a lossless-only decoder gate and accidental lossy/JPEG rewriting of the resource.
    func testLossyOriginalBytesAreRetained() async throws {
        let bytes = UploadWebPFixture.staticLossy.data, raw = try await stage(bytes)
        let value = try await TelegramUploadWebPIO.inspect(raw)
        XCTAssertEqual(value, .init(width: 320, height: 160))
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    // Frame0 may be a20x10 patch at(100,60); descriptor must describe the full320x160 canvas.
    func testAnimatedAndPartialFirstFrameUseCanvasWithoutFlatteningOriginal() async throws {
        for fixture in [UploadWebPFixture.animated, .partialCanvas] {
            let raw = try await stage(fixture.data)
            let value = try await TelegramUploadWebPIO.inspect(raw)
            XCTAssertEqual(value, .init(width: 320, height: 160))
            XCTAssertEqual(try Data(contentsOf: raw.url), fixture.data)
        }
    }

    // The probe owns decode safety, not the separate logical40pt/aspect photo-option rules.
    func testSmallWebPIsStillTypedWithIntrinsicDimensions() async throws {
        let raw = try await stage(UploadWebPFixture.small.data)
        let value = try await TelegramUploadWebPIO.inspect(raw)
        XCTAssertEqual(value, .init(width: 20, height: 10))
    }

    // Catches confusing filename claims or ordinary RIFF audio with recognizable WebP content.
    func testOrdinaryNonWebPReturnsNilEvenWithWebPSuffix() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABQAAAAKCAYAAAC0VX7mAAAAIUlEQVR4nGP8z8Dwn4GKgImahoHAqIGUAyYqmMEwwg0EAGvZAhJygE1MAAAAAElFTkSuQmCC")!
        for bytes in [Data(), Data("synthetic text".utf8), png, Data("RIFF0000WAVEsynthetic".utf8)] {
            let raw = try await stage(bytes, name: "claimed.webp")
            let value = try await TelegramUploadWebPIO.inspect(raw)
            XCTAssertNil(value)
        }
    }

    // ImageIO accepts trailing bytes and reports complete for a truncated count0 source; neither is valid here.
    func testRecognizableTruncationTrailingAndEmptyContainerFailClosed() async throws {
        let original = UploadWebPFixture.staticLossless.data
        var exactButUndecodable = Data(original.prefix(46)), length = UInt32(38).littleEndian
        withUnsafeBytes(of: &length) { exactButUndecodable.replaceSubrange(4..<8, with: $0) }
        for bytes in [Data(original.prefix(46)), original + Data([0]), exactButUndecodable,
                      Data([82,73,70,70,4,0,0,0,87,69,66,80])] {
            try await invalidWebP(bytes)
        }
    }

    // Actual native fixtures represent unsafe dimensions/frame counts despite tiny encoded size.
    func testOversizeCanvasAnd257FramesAreRefused() async throws {
        try await invalidWebP(UploadWebPFixture.overAxis.data)
        try await invalidWebP(uploadWebPAnimationFixture(frameCount: 257))
    }

    func test256FramesAreAdmittedWithoutRewriting() async throws {
        let bytes = try uploadWebPAnimationFixture(frameCount: 256), raw = try await stage(bytes)
        let value = try await TelegramUploadWebPIO.inspect(raw)
        XCTAssertEqual(value, .init(width: 320, height: 160))
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    // A large generic document remains ordinary; a recognizable WebP may not trigger unbounded decoding.
    func testEncodedByteLimitDistinguishesWebPFromGenericFile() async throws {
        var bytes = Data(repeating: 0, count: 20 * 1024 * 1024 + 1)
        let generic = try await stage(bytes), genericValue = try await TelegramUploadWebPIO.inspect(generic)
        XCTAssertNil(genericValue)
        bytes.replaceSubrange(0..<12, with: UploadWebPFixture.staticLossless.data.prefix(12))
        var length = UInt32(bytes.count - 8).littleEndian
        withUnsafeBytes(of: &length) { bytes.replaceSubrange(4..<8, with: $0) }
        try await invalidWebP(bytes)
    }

    // A valid-looking caller URL or wrong mode must never become a typed owned snapshot.
    func testNonOwnedAndNonFileStagesAreRefused() async throws {
        let source = try directory().appendingPathComponent("outside.webp")
        try writeUploadWebPFixture(source)
        let fake = TelegramUploadFile(id: UUID(), name: "outside.webp", size: 92, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: source, directory: source.deletingLastPathComponent())
        do { _ = try await TelegramUploadWebPIO.inspect(fake); XCTFail("Arbitrary URLs must be refused") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        let raw = try await stage(UploadWebPFixture.staticLossless.data)
        let photo = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .photo,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory)
        do { _ = try await TelegramUploadWebPIO.inspect(photo); XCTFail("Only raw file mode is admitted") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }

    // Catches following a replaced symlink or trusting a stale stage byte count.
    func testChangedOwnedStageAndSymlinkAreRefused() async throws {
        let changed = try await stage(UploadWebPFixture.staticLossless.data)
        try (UploadWebPFixture.staticLossless.data + Data([0])).write(to: changed.url)
        do { _ = try await TelegramUploadWebPIO.inspect(changed); XCTFail("Changed size must be refused") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        let linked = try await stage(UploadWebPFixture.staticLossless.data)
        let outside = try directory().appendingPathComponent("outside.webp")
        try writeUploadWebPFixture(outside)
        try FileManager.default.removeItem(at: linked.url)
        try FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: outside)
        do { _ = try await TelegramUploadWebPIO.inspect(linked); XCTFail("Symlink must be refused") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertEqual(try Data(contentsOf: outside), UploadWebPFixture.staticLossless.data)
    }

    // Cancellation is control flow rather than a routine unsupported-WebP result.
    func testCancellationPropagates() async throws {
        let raw = try await stage(UploadWebPFixture.staticLossless.data)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramUploadWebPIO.inspect(raw)
        }
        do { _ = try await task.value; XCTFail("Cancelled probe must throw") } catch is CancellationError {}
    }
}

import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MakoshTelegram

final class TelegramUploadSourceFactsIOTests: XCTestCase {
    private let itemID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func stage(_ data: Data, name: String) async throws -> TelegramUploadFile {
        let source = try directory().appendingPathComponent(name)
        try data.write(to: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(file) }
        try FileManager.default.removeItem(at: source)
        return file
    }

    private func image(_ width: Int, _ height: Int, type: UTType = .png, frames: Int = 1, dpi: Int = 72) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, pixels,
                [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // Catches using extension-less stage paths, stage UUIDs or generated payload MIME as source identity.
    func testOriginalNameMIMEAndLiteralHeldByteDigestArePreserved() async throws {
        let raw = try await stage(Data("abc".utf8), name: "source.MOV")
        do {
            let facts = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: raw, role: .original)
            XCTAssertEqual(facts.itemID, itemID); XCTAssertEqual(facts.role, .original)
            XCTAssertEqual(facts.name, "source.MOV"); XCTAssertEqual(facts.byteCount, 3)
            XCTAssertEqual(facts.plaintextSHA256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            XCTAssertEqual(facts.selectionMIME, "video/mov"); XCTAssertEqual(facts.image, .notImage)
            XCTAssertEqual(facts.grouping, .ordinary)
            XCTAssertEqual(try Data(contentsOf: raw.url), Data("abc".utf8))
        } catch { XCTFail("Owned ordinary source must inspect without writing: \(error)") }
    }

    // Catches changing source aliases that determine media options while leaving canonical byte probes separate.
    func testIndependentlyAuthoredSelectionMIMEAdapter() {
        let cases: [(String, String)] = [
            ("a.MOV", "video/mov"), ("a.m4v", "video/m4v"), ("a.mkv", "video/mkv"),
            ("a.ogg", "audio/ogg"), ("a.opus", "audio/ogg"), ("a.mp3", "audio/mpeg3"),
            ("a.webp", "image/webp"), ("a.gif", "image/gif"), ("a.png", "image/png"),
            ("opaque.unknownmakosh", "application/octet-stream"), ("noextension", "application/octet-stream")
        ]
        for (name, want) in cases { XCTAssertEqual(TelegramUploadSourceFactsIO.selectionMIME(for: name), want, name) }
    }

    // Catches applying source thresholds to pixels or normalized output instead of bounded native logical size.
    func testImageLogicalSizeRetainsDPIAndUndersizeResult() async throws {
        for (pixels, dpi, logical) in [(64, 144, 32.0), (32, 36, 64.0)] {
            let raw = try await stage(image(pixels, pixels, dpi: dpi), name: "source.png")
            do {
                let facts = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: raw, role: .original)
                XCTAssertEqual(facts.image, .decoded(width: logical, height: logical))
            } catch { XCTFail("Bounded image logical facts missing: \(error)") }
        }
    }

    // Catches incorrectly applying static-photo eligibility to source GIF/WebP option facts.
    func testGIFAndWebPProbeRemainSeparateFromStaticPayloadEligibility() async throws {
        let fixtures: [(Data, String, TelegramUploadSourceFacts.ImageProbe)] = [
            (try image(40, 40, type: .gif, frames: 2), "source.gif", .decoded(width: 40, height: 40)),
            (UploadWebPFixture.staticLossless.data, "source.webp", .decoded(width: 320, height: 160)),
            (UploadWebPFixture.animated.data, "animation.webp", .decoded(width: 320, height: 160))
        ]
        for (data, name, want) in fixtures {
            let raw = try await stage(data, name: name)
            do {
                let facts = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: raw, role: .original)
                XCTAssertEqual(facts.image, want); XCTAssertEqual(facts.grouping, .ordinary)
                XCTAssertEqual(try Data(contentsOf: raw.url), data)
            } catch { XCTFail("Source logical probe must accept supported animation: \(error)") }
        }
    }

    // Catches trusting corrupt claimed images, exceeding canvas/frame budgets or byte-sniffing an opaque name as image selection.
    func testCorruptOversizedAndOpaqueImagesDoNotAddImageSelectionFacts() async throws {
        let fixtures: [(Data, String, TelegramUploadSourceFacts.ImageProbe)] = [
            (Data("abc".utf8), "fake.png", .rejected),
            (UploadWebPFixture.overAxis.data, "huge.webp", .rejected),
            (try uploadWebPAnimationFixture(frameCount: 257), "many.webp", .rejected),
            (try image(40, 40), "opaque.bin", .notImage)
        ]
        for (data, name, want) in fixtures {
            let raw = try await stage(data, name: name)
            do {
                let value = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: raw, role: .prepared)
                XCTAssertEqual(value.image, want)
            }
            catch { XCTFail("Rejected image is a fact, not ownership failure: \(error)") }
        }
    }

    // Catches filename-only audio grouping and losing the existing opaque/misleading-name Opus adaptation.
    func testByteVerifiedAudioGroupingAndCanonicalMetadataEquality() async throws {
        let opus = try await stage(uploadOpusAudioFixture(), name: "opaque.bin")
        let audio = TelegramUploadAudioMetadata(duration: 1, title: " Synthetic Opus ", performer: "Synthetic Artist")
        do {
            let facts = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: opus, role: .prepared, metadata: .audio(audio))
            XCTAssertEqual(facts.selectionMIME, "application/x-macbinary"); XCTAssertEqual(facts.grouping, .music)
            XCTAssertEqual(facts.plaintextSHA256, "8bd827ac4da41877fd177a48dbb1c4d47c7f17c5f369d797ffbb75bd8ee4ceda")
        } catch { XCTFail("Verified canonical ordinary Opus must keep music facts: \(error)") }
        let claimed = try await stage(Data("abc".utf8), name: "claimed.mp3")
        do {
            let value = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: claimed, role: .prepared)
            XCTAssertEqual(value.grouping, .ordinary)
        }
        catch { XCTFail("Undecodable selected audio must remain ordinary: \(error)") }
        do {
            _ = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: opus, role: .prepared,
                metadata: .audio(.init(duration: 2, title: " Synthetic Opus ", performer: "Synthetic Artist")))
            XCTFail("Frozen canonical metadata mismatch must fail")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidAudio) }
    }

    // Catches treating recordable Opus bytes as explicit voice intent or allowing recording metadata into ordinary schema14.
    func testRecorderIntentIsNeverInferredAndExplicitRecorderMetadataIsRefused() async throws {
        let raw = try await stage(uploadOpusAudioFixture(), name: "ordinary.ogg")
        do {
            let value = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: raw, role: .prepared)
            XCTAssertEqual(value.grouping, .music)
        } catch { XCTFail("Ordinary selected Opus must probe as music: \(error)") }
        let voice = TelegramUploadVoiceMetadata(sampleCount: 60_000,
            plaintextSHA256: "8bd827ac4da41877fd177a48dbb1c4d47c7f17c5f369d797ffbb75bd8ee4ceda", waveform: Data())
        let round = TelegramUploadRoundVideoMetadata(nativeDuration: 1,
            plaintextSHA256: "8bd827ac4da41877fd177a48dbb1c4d47c7f17c5f369d797ffbb75bd8ee4ceda", isOneTime: false)
        for metadata in [TelegramUploadMetadata.voice(voice), .roundVideo(round)] {
            do { _ = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: raw, role: .prepared, metadata: metadata)
                XCTFail("Explicit recorder metadata belongs to schemas11–13")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        }
    }

    // Catches accepting a non-owned file, symlink payload or changed owned size as routine unsupported media.
    func testOwnershipSymlinkAndChangedSizeFailClosed() async throws {
        let outside = try directory().appendingPathComponent("outside")
        try Data("abc".utf8).write(to: outside)
        let fake = TelegramUploadFile(id: UUID(), name: "outside", size: 3, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: outside, directory: outside.deletingLastPathComponent())
        let linked = try await stage(Data("abc".utf8), name: "linked.png")
        try FileManager.default.removeItem(at: linked.url)
        try FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: outside)
        let changed = try await stage(Data("abc".utf8), name: "changed.txt")
        try Data("abcd".utf8).write(to: changed.url)
        for raw in [fake, linked, changed] {
            do { _ = try await TelegramUploadSourceFactsIO.inspect(itemID: itemID, raw: raw, role: .prepared)
                XCTFail("Ownership/mutation errors must propagate")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("abc".utf8))
    }

    // Catches cancellation being swallowed as a rejected image or ordinary grouping and consuming a borrowed stage.
    func testPreCancelledProbeThrowsAndPreservesBorrowedBytes() async throws {
        let raw = try await stage(Data("abc".utf8), name: "source.txt")
        let id = itemID
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramUploadSourceFactsIO.inspect(itemID: id, raw: raw, role: .prepared)
        }
        do { _ = try await task.value; XCTFail("Cancelled probe must throw") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: raw.url), Data("abc".utf8))
    }
}

import XCTest
import Foundation
import ImageIO
import Darwin
import CryptoKit
@testable import MakoshTelegram

@MainActor
final class TelegramUploadGIFIOTests: XCTestCase {
    private func stage(_ bytes: Data, name: String = "opaque.bin") async throws -> TelegramUploadFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(name)
        try bytes.write(to: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(file) }
        try FileManager.default.removeItem(at: source)
        return file
    }

    // Catches a nil classifier, suffix-only classification, clamped delay and raw rewriting.
    func testOwnedGIFReadsCanvasAndUnclampedTimingsWithoutChangingRawBytes() async throws {
        let file = try await stage(uploadGIFTimingFixture)
        let result = try await TelegramUploadGIFIO.inspect(file)
        let info = try XCTUnwrap(result)
        XCTAssertEqual(info.width, 32); XCTAssertEqual(info.height, 16)
        XCTAssertEqual(info.frameDurations, [Float(0.05), 0.2, 0.4])
        XCTAssertEqual(try Data(contentsOf: file.url), uploadGIFTimingFixture)
        XCTAssertNil(file.metadata); XCTAssertEqual(file.mode, .file)
    }

    // Catches losing the reference default and <.011 second rule.
    func testMissingZeroAndOneCentisecondDelayUsePointOne() async throws {
        let bytes = uploadGIFFixture([.init(color: 1, delay: nil), .init(color: 2, delay: 0),
            .init(color: 3, delay: 1), .init(color: 1, delay: 2)])
        let file = try await stage(bytes, name: "misleading.wav")
        let result = try await TelegramUploadGIFIO.inspect(file)
        XCTAssertEqual(try XCTUnwrap(result).frameDurations, [Float(0.1), 0.1, 0.1, 0.02])
    }

    // Catches using a partial frame's intrinsic bounds as the animation canvas.
    func testPartialFrameKeepsGlobalCanvas() async throws {
        let bytes = uploadGIFFixture([.init(color: 1, delay: 5),
            .init(color: 3, delay: 20, x: 8, y: 4, width: 8, height: 4)])
        let file = try await stage(bytes)
        let result = try await TelegramUploadGIFIO.inspect(file)
        XCTAssertEqual(try XCTUnwrap(result).width, 32)
        XCTAssertEqual(result?.height, 16); XCTAssertEqual(result?.frameDurations, [Float(0.05), 0.2])
    }

    // Catches claiming arbitrary documents from a GIF suffix.
    func testNonGIFReturnsNil() async throws {
        let file = try await stage(Data("synthetic text".utf8), name: "claimed.gif")
        let result = try await TelegramUploadGIFIO.inspect(file)
        XCTAssertNil(result)
        XCTAssertEqual(try Data(contentsOf: file.url), Data("synthetic text".utf8))
    }

    // Catches refusing a correctly bound immutable GIF or changing bytes during inspection.
    func testCorrectDigestReadsGIFWithoutChangingBytes() async throws {
        let bytes = uploadGIFTimingFixture
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = try await stage(bytes)
        let result = try await TelegramUploadGIFIO.inspect(file, expectedPlaintextSHA256: digest)
        let info = try XCTUnwrap(result)
        XCTAssertEqual(info.width, 32); XCTAssertEqual(info.height, 16)
        XCTAssertEqual(info.frameDurations, [Float(0.05), 0.2, 0.4])
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    // Catches ignoring the expected digest even though ImageIO accepts the GIF.
    func testWrongDigestRejectsGIF() async throws {
        let file = try await stage(uploadGIFTimingFixture)
        do {
            _ = try await TelegramUploadGIFIO.inspect(file, expectedPlaintextSHA256: String(repeating: "0", count: 64))
            XCTFail("A GIF with the wrong frozen digest must be unavailable")
        } catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
    }

    // Catches accepting noncanonical, missing-length or nonhex digest claims.
    func testMalformedDigestIsRejected() async throws {
        let bytes = uploadGIFTimingFixture
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = try await stage(bytes)
        for invalid in ["", String(repeating: "0", count: 63), String(repeating: "0", count: 65),
                        String(repeating: "g", count: 64), digest.uppercased()] {
            do {
                _ = try await TelegramUploadGIFIO.inspect(file, expectedPlaintextSHA256: invalid)
                XCTFail("Malformed frozen digest must be unavailable")
            } catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
        }
    }

    // Catches trusting equal canvas/timings/size after the owned bytes have changed.
    func testChangedSameFactsBytesRejectOriginalDigest() async throws {
        let original = uploadGIFTimingFixture
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        var changed = original
        changed[16] = 254 // Red palette component; all dimensions, frame data and delays stay unchanged.
        XCTAssertEqual(changed.count, original.count)
        XCTAssertNotEqual(changed, original)
        let file = try await stage(original)
        let before = try await TelegramUploadGIFIO.inspect(file)
        try changed.write(to: file.url)
        let after = try await TelegramUploadGIFIO.inspect(file)
        XCTAssertEqual(after, before)
        do {
            _ = try await TelegramUploadGIFIO.inspect(file, expectedPlaintextSHA256: digest)
            XCTFail("Equal GIF facts must not authorize different bytes")
        } catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
        XCTAssertEqual(try Data(contentsOf: file.url), changed)
    }

    // Catches treating nil classification as successful verification of a supplied digest.
    func testExpectedDigestOnNonGIFIsRejected() async throws {
        let bytes = Data("synthetic text".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = try await stage(bytes, name: "claimed.gif")
        do {
            _ = try await TelegramUploadGIFIO.inspect(file, expectedPlaintextSHA256: digest)
            XCTFail("An expected GIF digest must fail closed for non-GIF bytes")
        } catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
    }

    // Catches decoding GIF facts before rejecting a mismatched frozen byte binding.
    func testWrongDigestIsRejectedBeforeMalformedGIFFacts() async throws {
        let file = try await stage(Data(uploadGIFTimingFixture.prefix(18)))
        do {
            _ = try await TelegramUploadGIFIO.inspect(file, expectedPlaintextSHA256: String(repeating: "0", count: 64))
            XCTFail("Digest mismatch must throw before native GIF fact decoding")
        } catch { XCTAssertEqual(error as? TelegramUploadFileError, .unavailable) }
    }

    // Catches accepting malformed or excessive GIF before bounded native decoding.
    func testRecognizableUnsafeGIFIsRejected() async throws {
        var tooWide = uploadGIFTimingFixture; tooWide[6] = 1; tooWide[7] = 16
        var zeroCanvas = uploadGIFTimingFixture; zeroCanvas[6] = 0; zeroCanvas[7] = 0
        var tooLarge = uploadGIFTimingFixture; tooLarge.append(Data(count: 20 * 1024 * 1024 + 1 - tooLarge.count))
        let manyFrames = uploadGIFFixture(Array(repeating: .init(color: 1, delay: 5), count: 257))
        let workLimit = uploadGIFFixture(Array(repeating: .init(color: 1, delay: 5), count: 17), width: 4000, height: 4000)
        let pixelLimit = uploadGIFFixture([.init(color: 1, delay: 5)], width: 4001, height: 4000)
        let longTimeline = uploadGIFFixture([.init(color: 1, delay: 65_535)])
        for bytes in [Data(uploadGIFTimingFixture.prefix(18)), tooWide, zeroCanvas, tooLarge,
                      uploadGIFFixture([]), manyFrames, pixelLimit, workLimit, longTimeline] {
            let file = try await stage(bytes)
            do { _ = try await TelegramUploadGIFIO.inspect(file); XCTFail("Unsafe recognizable GIF must throw") }
            catch let error as TelegramUploadGIFError { XCTAssertEqual(error, .invalidGIF) }
        }
    }

    // Catches the foreign-path and permission bypasses of the owned snapshot.
    func testForeignOrRelaxedOwnedStageIsRejected() async throws {
        let file = try await stage(uploadGIFTimingFixture)
        let foreign = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: file.directory, directory: file.directory)
        do { _ = try await TelegramUploadGIFIO.inspect(foreign); XCTFail("Foreign URL must throw") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertEqual(chmod(file.url.path, 0o644), 0)
        defer { _ = chmod(file.url.path, 0o600) }
        do { _ = try await TelegramUploadGIFIO.inspect(file); XCTFail("Relaxed mode must throw") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }

    // Catches following a replacement symlink or trusting caller-supplied byte count.
    func testSymlinkAndForgedSizeAreRejected() async throws {
        let file = try await stage(uploadGIFTimingFixture)
        let forged = TelegramUploadFile(id: file.id, name: file.name, size: file.size + 1, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: file.url, directory: file.directory)
        do { _ = try await TelegramUploadGIFIO.inspect(forged); XCTFail("Forged size must throw") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        let saved = file.directory.appendingPathComponent("original")
        try FileManager.default.moveItem(at: file.url, to: saved)
        try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: saved)
        defer {
            try? FileManager.default.removeItem(at: file.url)
            try? FileManager.default.moveItem(at: saved, to: file.url)
        }
        do { _ = try await TelegramUploadGIFIO.inspect(file); XCTFail("Symlink must throw") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }

    // Catches dropping cancellation before native decoding.
    func testAlreadyCancelledInspectionPreservesOriginal() async throws {
        let file = try await stage(uploadGIFTimingFixture)
        let task = Task { try await TelegramUploadGIFIO.inspect(file) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task must throw") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: file.url), uploadGIFTimingFixture)
    }
}

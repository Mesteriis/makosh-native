import XCTest
import Foundation
import CryptoKit
@testable import MakoshTelegram

final class TelegramUploadOggAudioIOTests: XCTestCase {
    private func stage(_ bytes: Data, name: String = "opaque.bin") async throws -> TelegramUploadFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(name); try bytes.write(to: source)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(raw) }
        return raw
    }

    // Native sniffing previously misreported this real1.25s Opus as13 seconds.
    func testOrdinaryOpusBytesAreMusicWithoutFilenameOrRecorderIntent() async throws {
        let bytes = try await TelegramRecordedVoiceCodec.encode(samples: [Int16](repeating: 0, count: 60_000))
        let raw = try await stage(bytes)
        let audio = try await TelegramUploadAudioIO.inspect(raw)
        XCTAssertEqual(audio, .init(duration: 1, title: "", performer: ""))
        XCTAssertNil(raw.metadata)
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    // Independent encoder, multiple packets per page, pre-skip, final trimming and tags.
    func testIndependentOpusKeepsTagsWhitespaceGranuleDurationAndOriginalBytes() async throws {
        let bytes = try uploadOpusAudioFixture(), raw = try await stage(bytes, name: "misleading.mp4")
        XCTAssertEqual(bytes.count, 12_388)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "8bd827ac4da41877fd177a48dbb1c4d47c7f17c5f369d797ffbb75bd8ee4ceda")
        let metadata = try await TelegramUploadAudioIO.inspect(raw)
        XCTAssertEqual(metadata, .init(duration: 1, title: " Synthetic Opus ", performer: "Synthetic Artist"))
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    func testSubsecondAndChainedOpusUseTrimmedPCMCount() async throws {
        let small = try await TelegramRecordedVoiceCodec.encode(samples: [Int16](repeating: 0, count: 12_000))
        let short = try await stage(small)
        let shortMetadata = try await TelegramUploadAudioIO.inspect(short)
        XCTAssertEqual(shortMetadata.duration, 0)
        let first = try uploadOpusAudioFixture()
        var secondPages = pages(first)
        for index in secondPages.indices { secondPages[index].replaceSubrange(14..<18, with: [0x12, 0x34, 0x56, 0x78]) }
        let chained = first + repaired(secondPages), raw = try await stage(chained)
        let metadata = try await TelegramUploadAudioIO.inspect(raw)
        XCTAssertEqual(metadata, .init(duration: 2, title: " Synthetic Opus ", performer: "Synthetic Artist"))
        XCTAssertEqual(try Data(contentsOf: raw.url), chained)
    }

    func testCorruptCRCTruncatedTrailingMissingEOSAndPacketHolesAreRefused() async throws {
        let original = try uploadOpusAudioFixture(), sourcePages = pages(original)
        var crc = original; crc[300] ^= 1
        var noEOS = sourcePages; noEOS[noEOS.count - 1][5] = 0
        var hole = sourcePages; hole[2][18] = 6
        var multiplex = sourcePages; multiplex[2].replaceSubrange(14..<18, with: [1, 2, 3, 4])
        var continued = sourcePages; continued[2][5] |= 1
        for bytes in [crc, original.dropLast(), original + Data([0]), repaired(noEOS), repaired(hole), repaired(multiplex), repaired(continued)] {
            let raw = try await stage(Data(bytes))
            do { _ = try await TelegramUploadAudioIO.inspect(raw); XCTFail("Damaged Opus must not be repaired into music") }
            catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidAudio) }
        }
    }

    func testInvalidUTF8AndNULTagsCannotEnterTypedMetadata() async throws {
        let original = try uploadOpusAudioFixture()
        for replacement: UInt8 in [0, 0xff] {
            var sourcePages = pages(original)
            let range = try XCTUnwrap(sourcePages[1].range(of: Data("Synthetic Artist".utf8)))
            sourcePages[1][range.lowerBound] = replacement
            let raw = try await stage(repaired(sourcePages))
            do { _ = try await TelegramUploadAudioIO.inspect(raw); XCTFail("Invalid tags must not become trusted metadata") }
            catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidAudio) }
        }
    }

    func testCompletedAudioGranulesCannotInventDurationOrRequestRepair() async throws {
        let original = try uploadOpusAudioFixture()
        for (index, value) in [(3, Int64(480_312)), (2, Int64(-1))] {
            var sourcePages = pages(original)
            sourcePages[index].replaceSubrange(6..<14, with: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
            let raw = try await stage(repaired(sourcePages))
            do { _ = try await TelegramUploadAudioIO.inspect(raw); XCTFail("CRC-valid forged granules must be refused") }
            catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidAudio) }
        }
    }

    func testValidCroppedInitialGranuleOffsetPreservesDuration() async throws {
        var sourcePages = pages(try uploadOpusAudioFixture())
        for (index, value) in [(2, Int64(528_000)), (3, Int64(540_312))] {
            sourcePages[index].replaceSubrange(6..<14, with: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        let raw = try await stage(repaired(sourcePages))
        let metadata = try await TelegramUploadAudioIO.inspect(raw)
        XCTAssertEqual(metadata.duration, 1, "A valid cropped stream may start at a nonzero granule offset")
    }

    func testFirstAudioPageEOSAllowsEndTrimAndCroppedOffset() async throws {
        let original = pages(try uploadOpusAudioFixture())
        var laces = Data(), body = Data()
        for page in original.dropFirst(2) {
            let count = Int(page[26]); laces.append(page[27..<(27 + count)]); body.append(page.dropFirst(27 + count))
        }
        XCTAssertLessThanOrEqual(laces.count, 255)
        for granule: Int64 in [60_312, 540_312] {
            var header = Data(original[2].prefix(27)); header[5] = 4; header[26] = UInt8(laces.count)
            header.replaceSubrange(6..<14, with: (0..<8).map { UInt8(truncatingIfNeeded: granule >> ($0 * 8)) })
            let raw = try await stage(repaired([original[0], original[1], header + laces + body]))
            let metadata = try await TelegramUploadAudioIO.inspect(raw)
            XCTAssertEqual(metadata.duration, 1)
        }
    }

    func testOldWrongDurationFailsRevalidationWithoutRewriting() async throws {
        let raw = try await stage(uploadOpusAudioFixture())
        let stale = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory,
            metadata: .audio(.init(duration: 13, title: "", performer: "")))
        do { try await TelegramUploadFileIO.verifyMetadata(stale); XCTFail("Old misprobed facts cannot be silently accepted") }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidAudio) }
        XCTAssertEqual(try Data(contentsOf: raw.url), try uploadOpusAudioFixture())
    }

    func testAlreadyCancelledProbeCannotReturnMetadata() async throws {
        let raw = try await stage(uploadOpusAudioFixture())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramUploadAudioIO.inspect(raw)
        }
        do { _ = try await task.value; XCTFail("Cancelled work cannot publish metadata") } catch is CancellationError {}
    }

    func testContinuedCommentPacketAndStereoHeaderRemainOrdinaryMusic() async throws {
        let original = pages(try uploadOpusAudioFixture())
        var head = original[0]; head[28 + 9] = 2
        var tags = Data("OpusTags".utf8)
        func u32(_ value: UInt32) { tags.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        u32(0); u32(3)
        for comment in ["TITLE= Synthetic Opus ", "ARTIST=Synthetic Artist", "X=" + String(repeating: "x", count: 70_000)] {
            u32(UInt32(comment.utf8.count)); tags.append(contentsOf: comment.utf8)
        }
        let split = 65_025
        func commentPage(_ body: Data, sequence: UInt32, flag: UInt8, granule: Int64, laces: [UInt8]) -> Data {
            var header = Data(original[1].prefix(27)); header[5] = flag; header[26] = UInt8(laces.count)
            header.replaceSubrange(6..<14, with: (0..<8).map { UInt8(truncatingIfNeeded: granule >> ($0 * 8)) })
            header.replaceSubrange(18..<22, with: (0..<4).map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) })
            return header + Data(laces) + body
        }
        let start = commentPage(Data(tags.prefix(split)), sequence: 1, flag: 0, granule: -1, laces: [UInt8](repeating: 255, count: 255))
        let tail = Data(tags.dropFirst(split)), laces = [UInt8](repeating: 255, count: tail.count / 255) + [UInt8(tail.count % 255)]
        let end = commentPage(tail, sequence: 2, flag: 1, granule: 0, laces: laces)
        var audioPages = Array(original.dropFirst(2))
        for index in audioPages.indices { audioPages[index][18] += 1 }
        let raw = try await stage(repaired([head, start, end] + audioPages))
        let metadata = try await TelegramUploadAudioIO.inspect(raw)
        XCTAssertEqual(metadata, .init(duration: 1, title: " Synthetic Opus ", performer: "Synthetic Artist"))
    }

    private func pages(_ data: Data) -> [Data] {
        var result: [Data] = [], offset = 0
        while offset < data.count {
            let segments = Int(data[offset + 26])
            let size = 27 + segments + data[(offset + 27)..<(offset + 27 + segments)].reduce(0) { $0 + Int($1) }
            result.append(Data(data[offset..<(offset + size)])); offset += size
        }
        return result
    }

    // Independent fixture mutation: preserve page CRC so semantic checks are exercised.
    private func repaired(_ pages: [Data]) -> Data {
        var result = Data()
        for var page in pages {
            page.replaceSubrange(22..<26, with: [0, 0, 0, 0])
            var crc: UInt32 = 0
            for byte in page {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 { crc = crc & 0x8000_0000 == 0 ? crc << 1 : (crc << 1) ^ 0x04c1_1db7 }
            }
            page.replaceSubrange(22..<26, with: (0..<4).map { UInt8(truncatingIfNeeded: crc >> ($0 * 8)) })
            result.append(page)
        }
        return result
    }
}

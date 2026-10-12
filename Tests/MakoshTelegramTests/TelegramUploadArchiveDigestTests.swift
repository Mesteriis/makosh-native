import XCTest
import Foundation
import CryptoKit
@testable import MakoshTelegram

final class TelegramUploadArchiveDigestTests: XCTestCase {
    // Catches admitting a semantically valid ZIP under a different authenticated outer record.
    func testValidMembersDoNotReplaceTheAuthenticatedZIPDigest() async throws {
        let sources = try await sources()
        defer { sources.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let archive = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        try await TelegramUploadArchiveValidation.validate(archive, sources: sources)
        let expected = String(repeating: "0", count: 64)
        XCTAssertNotEqual(hash(try Data(contentsOf: archive.file.url)), expected)
        do {
            try await TelegramUploadArchiveValidation.validate(archive, sources: sources, expectedPlaintextSHA256: expected)
            XCTFail("Valid members admitted under the wrong outer ZIP digest")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }

    // Catches incomplete hashing of a ZIP spanning multiple bounded reads.
    func testAuthenticatedZIPDigestCoversEveryChunk() async throws {
        let sources = try await sources()
        defer { sources.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let archive = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        let bytes = try Data(contentsOf: archive.file.url)
        XCTAssertGreaterThan(bytes.count, 131_072)
        try await TelegramUploadArchiveValidation.validate(archive, sources: sources, expectedPlaintextSHA256: hash(bytes))
    }

    // Catches treating malformed or noncanonical authenticated digests as an absent binding.
    func testMalformedExpectedDigestIsRefused() async throws {
        let sources = try await sources()
        defer { sources.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let archive = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        for expected in ["", String(repeating: "0", count: 63), String(repeating: "g", count: 64), String(repeating: "A", count: 64)] {
            do {
                try await TelegramUploadArchiveValidation.validate(archive, sources: sources, expectedPlaintextSHA256: expected)
                XCTFail("Malformed expected digest admitted")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        }
    }

    private func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func sources() async throws -> [TelegramUploadArchiveIO.Source] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var state: UInt64 = 0x123456789abcdef
        var random = Data(count: 197_385)
        random.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for index in bytes.indices {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        var result: [TelegramUploadArchiveIO.Source] = []
        do {
            for (index, bytes) in [random, Data("Synthetic archive tail".utf8)].enumerated() {
                let url = directory.appendingPathComponent("digest-\(index).bin")
                try bytes.write(to: url)
                result.append(.init(itemID: UUID(), file: try await TelegramUploadFileIO.stage(url, mode: .file)))
            }
            return result
        } catch {
            result.forEach { try? TelegramUploadFileIO.discard($0.file) }
            throw error
        }
    }
}

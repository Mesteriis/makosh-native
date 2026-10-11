import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import MakoshTelegram

final class TelegramUploadArchiveValidationTests: XCTestCase {
    // Catches a validator which rejects real own output, consumes stages, or loses hidden/colliding names.
    func testValidWriterArchiveRetainsAllStagesAndChecksMultipleChunks() async throws {
        let names = ["same.txt", "same.txt", "same (2).txt", ".hidden", "é😀.txt", "empty.txt"]
        let values = [Data(repeating: 65, count: 131_073), Data("Second".utf8), Data("Reserved".utf8),
                      Data([0, 255, 1, 2]), Data("Unicode 😀".utf8), Data()]
        let sources = try await inputs(names: names, values: values)
        defer { discard(sources) }
        let archive = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        XCTAssertEqual(archive.members.map(\.entryName), ["same.txt", "same (3).txt", "same (2).txt", ".hidden", "é😀.txt", "empty.txt"])
        let before = try Data(contentsOf: archive.file.url)
        try await TelegramUploadArchiveValidation.validate(archive, sources: sources)
        XCTAssertEqual(try Data(contentsOf: archive.file.url), before)
        for (source, bytes) in zip(sources, values) { XCTAssertEqual(try Data(contentsOf: source.file.url), bytes) }
    }

    // Hand-authored raw DEFLATE "abc" + empty STORE fixture catches accepting only the writer's implementation.
    func testIndependentLiteralZIP32FixtureIsAccepted() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        XCTAssertEqual(archive.members[0].plaintextSHA256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(archive.members[1].plaintextSHA256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        try await TelegramUploadArchiveValidation.validate(archive, sources: sources)
    }

    // Catches trusting an authenticated member list without comparing it to both bytes and current source identities.
    func testManifestIdentityNameOrderSizeAndDigestTamperingIsRefused() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        let first = archive.members[0], second = archive.members[1]
        let variants: [[TelegramUploadArchiveIO.Member]] = [
            [second, first], [first], [first, first],
            [.init(itemID: UUID(), sourceName: first.sourceName, entryName: first.entryName, byteCount: 3, plaintextSHA256: first.plaintextSHA256), second],
            [.init(itemID: first.itemID, sourceName: "renamed.txt", entryName: first.entryName, byteCount: 3, plaintextSHA256: first.plaintextSHA256), second],
            [.init(itemID: first.itemID, sourceName: first.sourceName, entryName: "renamed.txt", byteCount: 3, plaintextSHA256: first.plaintextSHA256), second],
            [.init(itemID: first.itemID, sourceName: first.sourceName, entryName: first.entryName, byteCount: 2, plaintextSHA256: first.plaintextSHA256), second],
            [.init(itemID: first.itemID, sourceName: first.sourceName, entryName: first.entryName, byteCount: 3, plaintextSHA256: String(repeating: "0", count: 64)), second]
        ]
        for members in variants { await refused(.init(file: archive.file, members: members), sources: sources) }
    }

    // Catches verifying only archive bytes/manifest while same-length raw originals changed.
    func testFreshSourceDigestMustMatchArchivedMember() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        try Data([97, 98, 100]).write(to: sources[0].file.url)
        await refused(archive, sources: sources)
        XCTAssertEqual(try Data(contentsOf: sources[0].file.url), Data([97, 98, 100]))
    }

    // Catches accepting a different UTF8 source-name spelling because Swift String equality normalizes Unicode.
    func testSourceNameBindingPreservesExactUTF8Spelling() async throws {
        let sources = try await inputs(names: ["e\u{301}.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        let first = archive.members[0]
        let changed = TelegramUploadArchiveIO.Member(itemID: first.itemID, sourceName: "é.txt", entryName: first.entryName,
            byteCount: first.byteCount, plaintextSHA256: first.plaintextSHA256)
        await refused(.init(file: archive.file, members: [changed, archive.members[1]]), sources: sources)
    }

    // Each literal field mutation catches broad ZIP acceptance or incomplete local/central/EOCD cross-validation.
    func testEveryOwnHeaderFieldAndNameIsStrict() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        let bytes = try Data(contentsOf: archive.file.url)
        // Local1 starts0, Local2 starts40, central starts75, second central126, EOCD177.
        XCTAssertEqual(bytes.count, 199)
        let offsets = [0, 4, 6, 8, 10, 12, 14, 18, 22, 26, 28, 30,
                       40, 44, 46, 48, 50, 52, 54, 58, 62, 66, 68, 70,
                       75, 79, 81, 83, 85, 87, 89, 91, 95, 99, 103, 105, 107, 109, 111, 113, 117, 121,
                       126, 130, 132, 134, 136, 138, 140, 142, 146, 150, 154, 156, 158, 160, 162, 164, 168, 172,
                       177, 181, 183, 185, 187, 189, 193, 197]
        for offset in offsets {
            var changed = bytes; changed[offset] ^= 1
            try await refusedBytes(changed, members: archive.members, sources: sources, message: "Offset \(offset)")
        }
    }

    // Catches ignored trailing data, prepended self-extractors, truncated input, or unaccounted local/central gaps.
    func testExtraTrailingPrependedTruncatedAndGapBytesAreRefused() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        let original = try Data(contentsOf: archive.file.url)
        var gap = original; gap.insert(0, at: 75); gap.validationTestSet32(76, at: 194)
        for bytes in [original + Data([0]), Data([0]) + original, Data(original.dropLast()), gap] {
            try await refusedBytes(bytes, members: archive.members, sources: sources)
        }
    }

    // Catches accepting an early end, a second DEFLATE stream, malformed input, or a CRC-mismatched valid stream.
    func testCompressedStreamMustEndExactlyAndMatchCRCAndSHA() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        for compressed in [Data([0x4b, 0x4c, 0x4a, 0x06]), Data([0x4b, 0x4c, 0x4a, 0x06, 0x00, 0x00]),
                           Data([0x4b, 0x4c, 0x4a, 0x06, 0x00, 0x4b, 0x4c, 0x4a, 0x06, 0x00]),
                           Data([0xff]), Data([0x4b, 0x4c, 0x4a, 0x01, 0x00])] {
            let archive = try await handArchive(sources: sources, compressed: compressed)
            defer { try? TelegramUploadFileIO.discard(archive.file) }
            await refused(archive, sources: sources)
        }
    }

    // Catches checking only local==central CRC while neglecting the decoded bytes.
    func testConsistentlyForgedCRCIsRefused() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        var bytes = try Data(contentsOf: archive.file.url)
        bytes.validationTestSet32(0, at: 14); bytes.validationTestSet32(0, at: 91)
        try await refusedBytes(bytes, members: archive.members, sources: sources)
    }

    // Catches recalculating durable allocated names with a later allocator/OS instead of validating their exact bytes.
    func testSafeDurableEntryNamesAreAcceptedWithoutReallocation() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources, entryNames: [String(repeating: "a", count: 180) + " (2).txt", ".keep"])
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        try await TelegramUploadArchiveValidation.validate(archive, sources: sources)
    }

    // Catches unsafe/ambiguous extraction names even when ZIP headers and manifest agree exactly.
    func testDuplicateOrUnsafeDurableEntryNamesAreRefused() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        for names in [["a.txt", "a.txt"], ["A.txt", "a.txt"], ["e\u{301}.txt", "é.txt"],
                      ["../xx", "b.txt"], ["\\a.txt", "b.txt"], ["a:b", "b.txt"], ["a\n.txt", "b.txt"], [".", "b.txt"]] {
            let archive = try await handArchive(sources: sources, entryNames: names)
            defer { try? TelegramUploadFileIO.discard(archive.file) }
            await refused(archive, sources: sources)
        }
    }

    // Catches inflation exceeding the authenticated source count even with self-consistent declared sizes.
    func testInflatedByteCountCannotExceedBoundSourceSize() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources, firstSize: 2,
            firstDigest: "fb8e20fc2e4c3f248c60c39bd652f3c1347298bb977b8b4d5903b85055620603")
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        await refused(archive, sources: sources)
    }

    // Catches following a replaced source/ZIP symlink into another otherwise-valid owned stage.
    func testSourceAndArchiveSymlinksAreRefusedWithoutConsumingTargets() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        let target = try await stage(Data([97, 98, 99]), name: "target.bin")
        defer { try? TelegramUploadFileIO.discard(target) }
        try FileManager.default.removeItem(at: sources[0].file.url)
        try FileManager.default.createSymbolicLink(at: sources[0].file.url, withDestinationURL: target.url)
        await refused(archive, sources: sources)
        XCTAssertEqual(try Data(contentsOf: target.url), Data([97, 98, 99]))
        let other = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(other) }
        let second = try await handArchive(sources: other)
        defer { try? TelegramUploadFileIO.discard(second.file) }
        try FileManager.default.removeItem(at: archive.file.url)
        try FileManager.default.createSymbolicLink(at: archive.file.url, withDestinationURL: second.file.url)
        await refused(.init(file: archive.file, members: second.members), sources: other)
        XCTAssertEqual(try Data(contentsOf: second.file.url).count, 199)
    }

    // Catches over-limit aggregate reads and typed media being accepted as plain raw source stages.
    func testAggregateAndPlainSourcePreflightRefuseBeforeDecode() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        let raw = sources[0].file
        let typed = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .video,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory)
        await refused(archive, sources: [.init(itemID: sources[0].itemID, file: typed), sources[1]])
        let tooLarge = TelegramUploadFile(id: raw.id, name: raw.name, size: 1500 * 1024 * 1024 + 1, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory)
        await refused(archive, sources: [.init(itemID: sources[0].itemID, file: tooLarge), sources[1]])
        await refused(archive, sources: [sources[0], sources[0]])
    }

    // Catches cancellation being translated into generic corruption, or a cancelled worker publishing success.
    func testPreCancelledValidationThrowsCancellationAndPreservesInputs() async throws {
        let sources = try await inputs(names: ["a.txt", "b.txt"], values: [Data([97, 98, 99]), Data()])
        defer { discard(sources) }
        let archive = try await handArchive(sources: sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await TelegramUploadArchiveValidation.validate(archive, sources: sources)
        }
        do { try await task.value; XCTFail("Cancelled validation succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(try Data(contentsOf: sources[0].file.url), Data([97, 98, 99]))
        XCTAssertEqual(try Data(contentsOf: archive.file.url).count, 199)
    }

    private func refused(_ archive: TelegramUploadArchiveIO.Archive, sources: [TelegramUploadArchiveIO.Source],
                         message: String = "Invalid archive admitted", file: StaticString = #filePath, line: UInt = #line) async {
        do { try await TelegramUploadArchiveValidation.validate(archive, sources: sources); XCTFail(message, file: file, line: line) }
        catch { XCTAssertTrue(error is TelegramUploadFileError, "Unexpected \(error)", file: file, line: line) }
    }

    private func refusedBytes(_ bytes: Data, members: [TelegramUploadArchiveIO.Member], sources: [TelegramUploadArchiveIO.Source],
                              message: String = "Invalid archive admitted") async throws {
        let file = try await stage(bytes, name: "Telegram Archive.zip")
        defer { try? TelegramUploadFileIO.discard(file) }
        await refused(.init(file: file, members: members), sources: sources, message: message)
    }

    private func inputs(names: [String], values: [Data]) async throws -> [TelegramUploadArchiveIO.Source] {
        var result: [TelegramUploadArchiveIO.Source] = []
        for (name, data) in zip(names, values) { result.append(.init(itemID: UUID(), file: try await stage(data, name: name))) }
        return result
    }

    private func stage(_ data: Data, name: String) async throws -> TelegramUploadFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-validation-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.bin"); try data.write(to: source)
        let staged = try await TelegramUploadFileIO.stage(source, mode: .file)
        return TelegramUploadFile(id: staged.id, name: name, size: staged.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: staged.url, directory: staged.directory)
    }

    private func discard(_ sources: [TelegramUploadArchiveIO.Source]) {
        sources.forEach { try? TelegramUploadFileIO.discard($0.file) }
    }

    private func handArchive(sources: [TelegramUploadArchiveIO.Source],
                             compressed: Data = Data([0x4b, 0x4c, 0x4a, 0x06, 0x00]),
                             entryNames: [String] = ["a.txt", "b.txt"], firstSize: UInt32 = 3,
                             firstDigest: String = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") async throws -> TelegramUploadArchiveIO.Archive {
        var bytes = Data(), central = Data()
        for index in 0..<2 {
            let name = Data(entryNames[index].utf8), offset = UInt32(bytes.count)
            let flags: UInt16 = index == 0 ? 0x802 : 0x800, method: UInt16 = index == 0 ? 8 : 0
            let crc: UInt32 = index == 0 ? 0x352441c2 : 0, size: UInt32 = index == 0 ? firstSize : 0
            let encoded = index == 0 ? compressed : Data()
            bytes.validationTest32(0x04034b50); bytes.validationTest16(20); bytes.validationTest16(flags)
            bytes.validationTest16(method); bytes.validationTest16(0); bytes.validationTest16(0x21)
            bytes.validationTest32(crc); bytes.validationTest32(UInt32(encoded.count)); bytes.validationTest32(size)
            bytes.validationTest16(UInt16(name.count)); bytes.validationTest16(0); bytes.append(name); bytes.append(encoded)
            central.validationTest32(0x02014b50); central.validationTest16(20); central.validationTest16(20)
            central.validationTest16(flags); central.validationTest16(method); central.validationTest16(0); central.validationTest16(0x21)
            central.validationTest32(crc); central.validationTest32(UInt32(encoded.count)); central.validationTest32(size)
            central.validationTest16(UInt16(name.count)); central.validationTest16(0); central.validationTest16(0)
            central.validationTest16(0); central.validationTest16(0); central.validationTest32(0)
            central.validationTest32(offset); central.append(name)
        }
        let centralOffset = UInt32(bytes.count); bytes.append(central)
        bytes.validationTest32(0x06054b50); bytes.validationTest16(0); bytes.validationTest16(0)
        bytes.validationTest16(2); bytes.validationTest16(2); bytes.validationTest32(UInt32(central.count))
        bytes.validationTest32(centralOffset); bytes.validationTest16(0)
        let file = try await stage(bytes, name: "Telegram Archive.zip")
        let members = sources.enumerated().map { index, source in
            TelegramUploadArchiveIO.Member(itemID: source.itemID, sourceName: source.file.name, entryName: entryNames[index],
                byteCount: index == 0 ? Int64(firstSize) : 0,
                plaintextSHA256: index == 0 ? firstDigest : "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        }
        return .init(file: file, members: members)
    }
}

private extension Data {
    mutating func validationTest16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func validationTest32(_ value: UInt32) { validationTest16(UInt16(truncatingIfNeeded: value)); validationTest16(UInt16(truncatingIfNeeded: value >> 16)) }
    mutating func validationTestSet32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}

import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import MakoshTelegram

final class TelegramUploadArchiveIOTests: XCTestCase {
    // Catches dropping duplicate basenames, hidden files, order, or emitting a non-interoperable ZIP.
    func testOrderedArchivePreservesEveryRawMemberAndCompressesWithIndependentReader() async throws {
        let names = ["same.txt", "same.txt", "same (2).txt", ".hidden", "é😀.txt", "empty.txt"]
        let values = [Data(repeating: 65, count: 131_072), Data("Second".utf8), Data("Reserved".utf8),
                      Data([0, 255, 1, 2]), Data("Unicode 😀".utf8), Data()]
        let inputs = try await zipInputs(names: names, values: values)
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let result = try await TelegramUploadArchiveIO.prepare(inputs)
        defer { try? TelegramUploadFileIO.discard(result.file) }
        XCTAssertEqual(result.file.name, "Telegram Archive.zip"); XCTAssertEqual(result.file.mode, .file)
        XCTAssertNil(result.file.metadata); try TelegramUploadFileIO.validateOwnedStage(result.file)
        let expected = ["same.txt", "same (3).txt", "same (2).txt", ".hidden", "é😀.txt", "empty.txt"]
        XCTAssertEqual(result.members.map(\.itemID), inputs.map(\.itemID))
        XCTAssertEqual(result.members.map(\.sourceName), names); XCTAssertEqual(result.members.map(\.entryName), expected)
        XCTAssertEqual(result.members.map(\.byteCount), values.map { Int64($0.count) })
        XCTAssertEqual(result.members.map(\.plaintextSHA256), values.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
        let entries = try independentZIP(result.file.url)
        XCTAssertEqual(entries.map { $0["name"] as? String }, expected)
        XCTAssertEqual(entries.map { $0["base64"] as? String }, values.map { $0.base64EncodedString() })
        XCTAssertEqual(entries.map { ($0["method"] as? NSNumber)?.intValue }, [8, 8, 8, 8, 8, 0])
        XCTAssertLessThan(try XCTUnwrap(entries[0]["compressed"] as? Int), 1_000)
        XCTAssertTrue(entries.dropLast().allSatisfy { (($0["flags"] as? Int) ?? 0) & 0x800 != 0 })
        for (input, value) in zip(inputs, values) { XCTAssertEqual(try Data(contentsOf: input.file.url), value) }
    }

    // Catches archive extraction overwriting a case or canonical-equivalent Unicode basename.
    func testPortableCollisionNamesKeepReservedLaterNames() async throws {
        let names = ["A.txt", "a.txt", "a (2).txt", "e\u{301}.txt", "é.txt"]
        let inputs = try await zipInputs(names: names, values: names.map { Data($0.utf8) })
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let result = try await TelegramUploadArchiveIO.prepare(inputs)
        defer { try? TelegramUploadFileIO.discard(result.file) }
        XCTAssertEqual(result.members.map(\.entryName), ["A.txt", "a (3).txt", "a (2).txt", "e\u{301}.txt", "é (2).txt"])
        XCTAssertEqual(try independentZIP(result.file.url).count, 5)
    }

    // Catches admitting a single/double identity, foreign path, or a mutated raw stage.
    func testInvalidMemberSetIsRefusedWithoutChangingSources() async throws {
        let inputs = try await zipInputs(names: ["one.txt", "two.txt"], values: [Data([1]), Data([2])])
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        for invalid in [[], [inputs[0]], [inputs[0], inputs[0]]] {
            do { _ = try await TelegramUploadArchiveIO.prepare(invalid); XCTFail("Invalid member set admitted") }
            catch is TelegramUploadFileError {}
        }
        try Data([3, 4]).write(to: inputs[1].file.url)
        do { _ = try await TelegramUploadArchiveIO.prepare(inputs); XCTFail("Changed source admitted") }
        catch is TelegramUploadFileError {}
        XCTAssertEqual(try Data(contentsOf: inputs[0].file.url), Data([1]))
    }

    // Catches publishing a ZIP that its inspector refuses because output and source identities overlap.
    func testArchiveIdentityCannotReuseSourceItemOrFileIdentity() async throws {
        let values = [Data([1]), Data([2])]
        let inputs = try await zipInputs(names: ["one.txt", "two.txt"], values: values)
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        for id in [inputs[0].itemID, inputs[0].file.id] {
            let progress = ArchiveProgressObservation()
            do {
                let unexpected = try await TelegramUploadArchiveIO.prepare(inputs, id: id, progress: progress.append)
                try? TelegramUploadFileIO.discard(unexpected.file)
                XCTFail("Overlapping archive identity admitted")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
            XCTAssertTrue(progress.values.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory(inputs[0].itemID).path))
        for (input, bytes) in zip(inputs, values) { XCTAssertEqual(try Data(contentsOf: input.file.url), bytes) }
    }

    // Catches accepting a syntactically owned zero-ID raw stage that the inspector rejects.
    func testZeroSourceFileIdentityIsRefusedBeforeOutputCreation() async throws {
        let inputs = try await zipInputs(names: ["one.txt", "two.txt"], values: [Data([1]), Data([2])])
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let directory = archiveDirectory(zero)
        guard mkdir(directory.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("payload-" + zero.uuidString)
        try Data([1]).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        let file = TelegramUploadFile(id: zero, name: "one.txt", size: 1, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: url, directory: directory)
        try TelegramUploadFileIO.validateOwnedStage(file)
        let sources = [TelegramUploadArchiveIO.Source(itemID: inputs[0].itemID, file: file), inputs[1]]
        let id = UUID(), progress = ArchiveProgressObservation()
        do {
            let unexpected = try await TelegramUploadArchiveIO.prepare(sources, id: id, progress: progress.append)
            try? TelegramUploadFileIO.discard(unexpected.file)
            XCTFail("Zero source identity admitted")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertTrue(progress.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory(id).path))
        XCTAssertEqual(try Data(contentsOf: url), Data([1]))
        XCTAssertEqual(try Data(contentsOf: inputs[1].file.url), Data([2]))
    }

    // Catches reading/compressing an over-limit sparse input before aggregate preflight.
    func testAggregateLimitRefusesSparseSourceBeforeCompression() async throws {
        let inputs = try await zipInputs(names: ["large.bin", "tail.txt"], values: [Data(), Data([1])])
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let fd = Darwin.open(inputs[0].file.url.path, O_WRONLY | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        let size: Int64 = 1500 * 1024 * 1024
        XCTAssertEqual(ftruncate(fd, size), 0)
        let raw = inputs[0].file
        let large = TelegramUploadFile(id: raw.id, name: raw.name, size: size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory)
        do {
            _ = try await TelegramUploadArchiveIO.prepare([.init(itemID: inputs[0].itemID, file: large), inputs[1]])
            XCTFail("Oversized aggregate admitted")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .tooLarge) }
    }

    // Catches publishing an archive for an operation already cancelled by its owner.
    func testPreCancelledArchiveDoesNotProduceAResult() async throws {
        let inputs = try await zipInputs(names: ["one.txt", "two.txt"], values: [Data([1]), Data([2])])
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramUploadArchiveIO.prepare(inputs)
        }
        do { _ = try await task.value; XCTFail("Cancelled archive published") } catch is CancellationError {}
    }

    // Catches cancellation after compression started leaving a partial ZIP or consuming raw inputs.
    func testInFlightCancellationRemovesOutputAndPreservesRawSources() async throws {
        let values = [Data(repeating: 65, count: 131_072), Data(repeating: 66, count: 131_072)]
        let inputs = try await zipInputs(names: ["one.bin", "two.bin"], values: values)
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let id = UUID(), progress = ArchiveProgressObservation()
        do {
            let unexpected = try await TelegramUploadArchiveIO.prepare(inputs, id: id) { fraction in
                progress.append(fraction)
                if fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            try? TelegramUploadFileIO.discard(unexpected.file)
            XCTFail("In-flight cancellation published a ZIP")
        } catch is CancellationError {}
        XCTAssertTrue(progress.values.contains { $0 > 0 && $0 < 1 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory(id).path))
        for (input, bytes) in zip(inputs, values) { XCTAssertEqual(try Data(contentsOf: input.file.url), bytes) }
    }

    // Catches a source replaced after its member was compressed being paired with newer originals.
    func testMutationAfterFirstMemberInvalidatesEntireOutput() async throws {
        let values = [Data(repeating: 65, count: 65_536), Data(repeating: 66, count: 65_536)]
        let inputs = try await zipInputs(names: ["one.bin", "two.bin"], values: values)
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let id = UUID(), progress = ArchiveProgressObservation()
        do {
            let unexpected = try await TelegramUploadArchiveIO.prepare(inputs, id: id) { fraction in
                progress.append(fraction)
                if fraction == 0.5 { try? Data(repeating: 67, count: 65_536).write(to: inputs[0].file.url) }
            }
            try? TelegramUploadFileIO.discard(unexpected.file)
            XCTFail("A changed source produced a ZIP")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        XCTAssertTrue(progress.values.contains(0.5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory(id).path))
        XCTAssertEqual(try Data(contentsOf: inputs[1].file.url), values[1])
    }

    // Catches reporting success before all selected bytes have been compressed and checked.
    func testProgressReachesCompletionOnlyForPublishedArchive() async throws {
        let inputs = try await zipInputs(names: ["one.bin", "empty.bin"], values: [Data(repeating: 65, count: 131_072), Data()])
        defer { inputs.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let id = UUID(), progress = ArchiveProgressObservation()
        let result = try await TelegramUploadArchiveIO.prepare(inputs, id: id, progress: progress.append)
        defer { try? TelegramUploadFileIO.discard(result.file) }
        XCTAssertEqual(result.file.id, id)
        XCTAssertEqual(progress.values.first, 0); XCTAssertEqual(progress.values.last, 1)
        XCTAssertEqual(progress.values, progress.values.sorted())
        XCTAssertTrue(progress.values.contains { $0 > 0 && $0 < 1 })
        XCTAssertEqual(try independentZIP(result.file.url).count, 2)
    }

    // Exercises exact output-buffer sizes and multiple incompressible input chunks in both codecs.
    func testDeflateAndInflateAcrossExactBufferBoundariesWithIndependentReader() async throws {
        var state: UInt64 = 0x123456789abcdef
        let counts = [65_535, 65_536, 65_537, 131_072, 131_073, 197_385]
        var values = [Data(repeating: 65, count: 65_536), Data(repeating: 66, count: 131_072)]
        for count in counts {
            var bytes = Data(count: count)
            bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                for index in 0..<count {
                    state ^= state << 13; state ^= state >> 7; state ^= state << 17
                    buffer[index] = UInt8(truncatingIfNeeded: state >> 24)
                }
            }
            values.append(bytes)
        }
        let sources = try await zipInputs(names: values.indices.map { "boundary-\($0).bin" }, values: values)
        defer { sources.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        let archive = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        XCTAssertEqual(try independentZIP(archive.file.url).map { $0["base64"] as? String }, values.map { $0.base64EncodedString() })
        try await TelegramUploadArchiveValidation.validate(archive, sources: sources)
    }

    private func archiveDirectory(_ id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + id.uuidString)
    }

    private func zipInputs(names: [String], values: [Data]) async throws -> [TelegramUploadArchiveIO.Source] {
        var result: [TelegramUploadArchiveIO.Source] = []
        for (name, bytes) in zip(names, values) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-zip-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("input.bin"); try bytes.write(to: source)
            let staged = try await TelegramUploadFileIO.stage(source, mode: .file)
            let named = TelegramUploadFile(id: staged.id, name: name, size: staged.size, mode: .file,
                pixelWidth: nil, pixelHeight: nil, url: staged.url, directory: staged.directory)
            result.append(.init(itemID: UUID(), file: named))
        }
        return result
    }

    private func independentZIP(_ url: URL) throws -> [[String: Any]] {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import sys,zipfile,json,base64; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(json.dumps([dict(name=i.filename,base64=base64.b64encode(z.read(i)).decode(),method=i.compress_type,flags=i.flag_bits,compressed=i.compress_size) for i in z.infolist()]))", url.path]
        process.standardOutput = output; process.standardError = errors
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Reader failed")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
    }
}

private final class ArchiveProgressObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

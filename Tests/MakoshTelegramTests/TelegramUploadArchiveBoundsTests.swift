import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramUploadArchiveBoundsTests: XCTestCase {
    // Catches metadata-only exhaustion before any source path is opened.
    func testMemberCountLimitPrecedesSourceIOInWriterAndInspector() async throws {
        let fixture = try await fixture()
        defer { discard(fixture) }
        let sources = unownedSources(names: (0..<1025).map { "entry-\($0).txt" })
        await tooLarge { _ = try await TelegramUploadArchiveIO.prepare(sources) }
        await tooLarge { try await TelegramUploadArchiveValidation.validate(manifest(fixture.archive.file, sources), sources: sources) }
    }

    // A grapheme limit alone permits thousands of UTF8 bytes in one filename.
    func testSourceUTF8NameLimitPrecedesNormalizationAndSourceIO() async throws {
        let fixture = try await fixture()
        defer { discard(fixture) }
        let sources = unownedSources(names: ["a" + String(repeating: "\u{301}", count: 512) + ".txt", "two.txt"])
        await tooLarge { _ = try await TelegramUploadArchiveIO.prepare(sources) }
        await tooLarge { try await TelegramUploadArchiveValidation.validate(manifest(fixture.archive.file, sources), sources: sources) }
    }

    // Catches individually allowed names accumulating an oversized central directory.
    func testCentralDirectoryBudgetPrecedesSourceIO() async throws {
        let fixture = try await fixture()
        defer { discard(fixture) }
        let names = (0..<1024).map { "\($0)" + String(repeating: "\u{301}", count: 507) + ".txt" }
        let sources = unownedSources(names: names)
        await tooLarge { _ = try await TelegramUploadArchiveIO.prepare(sources) }
        await tooLarge { try await TelegramUploadArchiveValidation.validate(manifest(fixture.archive.file, sources), sources: sources) }
    }

    // Catches oversized durable entry names reaching Unicode normalization or header reads.
    func testInspectorBoundsDurableAllocatedNameBeforeSourceIO() async throws {
        let fixture = try await fixture()
        defer { discard(fixture) }
        let sources = unownedSources(names: ["one.txt", "two.txt"])
        let ordinary = manifest(fixture.archive.file, sources)
        let oversized = TelegramUploadArchiveIO.Member(itemID: sources[0].itemID, sourceName: sources[0].file.name,
            entryName: "a" + String(repeating: "\u{301}", count: 520), byteCount: 0,
            plaintextSHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        await tooLarge {
            try await TelegramUploadArchiveValidation.validate(.init(file: ordinary.file, members: [oversized, ordinary.members[1]]), sources: sources)
        }
    }

    // Catches a count guard accidentally refusing the supported upper boundary.
    func testExactly1024SmallMembersCanBeWrittenAndValidated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-archive-count-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("empty.bin"); try Data().write(to: url)
        var sources: [TelegramUploadArchiveIO.Source] = []
        defer { sources.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        for index in 0..<1024 {
            let raw = try await TelegramUploadFileIO.stage(url, mode: .file)
            sources.append(.init(itemID: UUID(), file: TelegramUploadFile(id: raw.id, name: "entry-\(index).bin",
                size: raw.size, mode: .file, pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory)))
        }
        let archive = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(archive.file) }
        XCTAssertEqual(archive.members.count, 1024)
        try await TelegramUploadArchiveValidation.validate(archive, sources: sources)
    }

    private func tooLarge(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Metadata budget was not enforced", file: file, line: line) }
        catch let error as TelegramUploadFileError { XCTAssertEqual(error, .tooLarge, file: file, line: line) }
        catch { XCTFail("Unexpected error \(error)", file: file, line: line) }
    }

    private func unownedSources(names: [String]) -> [TelegramUploadArchiveIO.Source] {
        names.map { name in
            let id = UUID(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + id.uuidString)
            return .init(itemID: UUID(), file: TelegramUploadFile(id: id, name: name, size: 0, mode: .file,
                pixelWidth: nil, pixelHeight: nil, url: directory.appendingPathComponent("payload-" + id.uuidString), directory: directory))
        }
    }

    private func manifest(_ file: TelegramUploadFile, _ sources: [TelegramUploadArchiveIO.Source]) -> TelegramUploadArchiveIO.Archive {
        .init(file: file, members: sources.map {
            .init(itemID: $0.itemID, sourceName: $0.file.name, entryName: $0.file.name, byteCount: 0,
                plaintextSHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        })
    }

    private func fixture() async throws -> (sources: [TelegramUploadArchiveIO.Source], archive: TelegramUploadArchiveIO.Archive) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-archive-bounds-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("empty.txt"); try Data().write(to: url)
        let sources = try await [TelegramUploadArchiveIO.Source(itemID: UUID(), file: TelegramUploadFileIO.stage(url, mode: .file)),
                                 TelegramUploadArchiveIO.Source(itemID: UUID(), file: TelegramUploadFileIO.stage(url, mode: .file))]
        return (sources, try await TelegramUploadArchiveIO.prepare(sources))
    }

    private func discard(_ fixture: (sources: [TelegramUploadArchiveIO.Source], archive: TelegramUploadArchiveIO.Archive)) {
        fixture.sources.forEach { try? TelegramUploadFileIO.discard($0.file) }
        try? TelegramUploadFileIO.discard(fixture.archive.file)
    }
}

import Foundation
import XCTest
@testable import MakoshFiles

final class FilePreviewLeaseTests: XCTestCase {
    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testLeaseCreatesPrivateFileAndRemovesDirectoryOnRelease() async throws {
        var lease: FilePreviewLease? = try await FilePreviewLease.create(name: "Счёт за ноябрь.PDF") { url in
            try Data("%PDF-".utf8).write(to: url)
        }
        let file = try XCTUnwrap(lease?.file)
        XCTAssertEqual(file.lastPathComponent, "file.PDF", "a generic stem with the short ASCII extension")
        XCTAssertEqual(lease?.name, "Счёт за ноябрь.PDF")
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try Data(contentsOf: file), Data("%PDF-".utf8))
        let odd = try await FilePreviewLease.create(name: "отчёт.тхт") { url in try Data().write(to: url) }
        XCTAssertEqual(odd.file.lastPathComponent, "file", "a non-ASCII extension is dropped")
        let long = try await FilePreviewLease.create(name: "x." + String(repeating: "a", count: 17)) { url in try Data().write(to: url) }
        XCTAssertEqual(long.file.lastPathComponent, "file", "an overlong extension is dropped")
        let directory = file.deletingLastPathComponent()
        lease = nil
        for _ in 0..<10 where FileManager.default.fileExists(atPath: directory.path) { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testLeaseExportFailureLeavesNoDirectory() async throws {
        let before = Set(
            try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter {
                $0.hasPrefix("makosh-file-preview-")
            })
        do {
            _ = try await FilePreviewLease.create(name: "a.pdf") { _ in throw FilesFailure.integrity }
            XCTFail("the export failure must propagate")
        } catch let error as FilesFailure { XCTAssertEqual(error, .integrity) }
        let after = Set(
            try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter {
                $0.hasPrefix("makosh-file-preview-")
            })
        XCTAssertEqual(after, before)
    }
}

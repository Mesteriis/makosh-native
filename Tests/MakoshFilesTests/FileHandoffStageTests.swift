import Foundation
import XCTest
@testable import MakoshFiles

final class FileHandoffStageTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-stage-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }
    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testStagedFileIsPrivateAndFoundByID() async throws {
        let stage = FileHandoffStage(root: root)
        let staged = try await stage.stage(FileHandoff(name: "Счёт.pdf") { url in try Data("%PDF-".utf8).write(to: url) })
        XCTAssertEqual(staged.name, "Счёт.pdf")
        XCTAssertEqual(staged.url.lastPathComponent, "file.pdf")
        XCTAssertEqual(try mode(staged.url), 0o600)
        XCTAssertEqual(try mode(staged.url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(root), 0o700)
        let found = await stage.url(id: staged.id)
        XCTAssertEqual(found, staged.url)
        XCTAssertEqual(try Data(contentsOf: staged.url), Data("%PDF-".utf8))
    }

    func testReleaseRemovesTheCopyAndForgetsTheID() async throws {
        let stage = FileHandoffStage(root: root)
        let staged = try await stage.stage(FileHandoff(name: "a.txt") { url in try Data("x".utf8).write(to: url) })
        await stage.release(id: staged.id)
        let gone = await stage.url(id: staged.id)
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.deletingLastPathComponent().path))
    }

    func testClearAllRemovesLeftoversFromEarlierRuns() async throws {
        let leftover = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: leftover.appendingPathComponent("file"))
        let stage = FileHandoffStage(root: root)
        await stage.clearAll()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let staged = try await stage.stage(FileHandoff(name: "b.txt") { url in try Data("y".utf8).write(to: url) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path), "staging works after clearing")
    }

    func testStagedCopyOutlivesItsSource() async throws {
        // A Teams lease is removed when its preview closes; the staged copy must not depend on it.
        let lease = root.appendingPathComponent("lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: true)
        let source = lease.appendingPathComponent("slides.pptx")
        try Data("PK slides".utf8).write(to: source)
        let stage = FileHandoffStage(root: root)
        let staged = try await stage.stage(FileHandoff(copying: source, name: "Презентация.pptx"))
        try FileManager.default.removeItem(at: lease)
        let again = FileHandoff(copying: staged.url, name: staged.name)
        let destination = root.appendingPathComponent("again.pptx")
        try await again.produce(destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("PK slides".utf8))
        XCTAssertEqual(again.name, "Презентация.pptx")
    }

    func testFailedProduceLeavesNothingBehind() async throws {
        let stage = FileHandoffStage(root: root)
        do {
            _ = try await stage.stage(FileHandoff(name: "a.txt") { _ in throw FilesFailure.integrity })
            XCTFail("the failure propagates")
        } catch let error as FilesFailure { XCTAssertEqual(error, .integrity) }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [], [])
    }
}

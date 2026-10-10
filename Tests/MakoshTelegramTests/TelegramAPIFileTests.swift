import XCTest
import Foundation
import Darwin
@testable import MakoshTelegram

final class TelegramAPIFileTests: XCTestCase {
    private var directory: URL!
    private let syntheticHash = String(repeating: "a", count: 32)
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }
    private func write(_ data: Data, mode: Int = 0o600) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }
    private func validData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["apiID": "12345", "apiHash": syntheticHash])
    }
    private func assertSafeFailure(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TelegramAPIFile.load(from: url), file: file, line: line) { error in
            XCTAssertEqual(error.localizedDescription, "Не удалось загрузить настройки Telegram. Проверьте личный JSON-файл настроек и права доступа 0600.", file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains(self.syntheticHash), file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-marker"), file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains(url.path), file: file, line: line)
        }
    }
    func testLoadsOwnedRegular0600File() throws {
        let url = try write(validData())
        let result = try TelegramAPIFile.load(from: url)
        XCTAssertEqual(result.id, 12345)
        XCTAssertEqual(result.hash, syntheticHash)
    }
    func testRejectsGroupOrWorldPermissions() throws {
        for mode in [0o644, 0o640, 0o604, 0o601, 0o610] {
            assertSafeFailure(try write(validData(), mode: mode))
        }
    }
    func testRejectsSymlinkWithoutFollowingIt() throws {
        let target = try write(validData())
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        assertSafeFailure(link)
        XCTAssertEqual(try TelegramAPIFile.load(from: target).id, 12345)
    }
    func testRejectsMalformedJSONAndInvalidConfigurationWithoutLeakingContent() throws {
        assertSafeFailure(try write(Data("synthetic-private-marker {".utf8)))
        let documents: [[String: Any]] = [
            ["apiID": "synthetic-private-marker", "apiHash": syntheticHash],
            ["apiID": "12345", "apiHash": "synthetic-private-marker"],
            ["apiID": 12345, "apiHash": syntheticHash],
            ["apiID": "12345"]
        ]
        for document in documents {
            assertSafeFailure(try write(JSONSerialization.data(withJSONObject: document)))
        }
    }
    func testRejectsOversizeFileAndMissingFileWithSafeErrors() throws {
        assertSafeFailure(try write(Data(repeating: 65, count: 8193)))
        assertSafeFailure(directory.appendingPathComponent("missing.json"))
    }
    func testRejectsDirectoryAndFIFOWithoutBlocking() throws {
        assertSafeFailure(directory)
        let fifo = directory.appendingPathComponent("special.json")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        assertSafeFailure(fifo)
    }
}

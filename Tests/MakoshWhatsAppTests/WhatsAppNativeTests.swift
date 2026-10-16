import Foundation
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppNativeTests: XCTestCase {
  func testCloseCompletesOnTheDedicatedExecutorWithoutARunLoop() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let executable = root.appendingPathComponent(".local/whatsapp-runtime/MakoshWhatsAppWorker")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "makosh-wa-close-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let finished = expectation(description: "Owned helper teardown finishes")
    Task {
      do {
        for _ in 0..<10 {
          let session = WhatsAppNativeSession(executable: executable)
          try await session.open(directory: directory, key: Data(repeating: 0x72, count: 32))
          let competing = WhatsAppNativeSession(executable: executable)
          do {
            try await competing.open(directory: directory, key: Data(repeating: 0x72, count: 32))
            XCTFail("Exclusive owner")
          } catch {}
          try await session.close()
        }
      } catch { XCTFail("Offline helper teardown failed") }
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 10)
  }
  func testSeparateProcessStartsOfflineAndPreservesEncryptedSession() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let executable = root.appendingPathComponent(".local/whatsapp-runtime/MakoshWhatsAppWorker")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: executable.path),
      "Run scripts/prepare-whatsapp.py")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "makosh-wa-native-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = Data(repeating: 0x73, count: 32)
    let first = WhatsAppNativeSession(executable: executable)
    try await first.open(directory: directory, key: key)
    let status = try await first.status()
    XCTAssertEqual(status.state, "offline")
    XCTAssertTrue(status.qr.isEmpty)
    let chats = try await first.chats(before: nil)
    XCTAssertTrue(chats.isEmpty)
    let journal = try await first.journal()
    XCTAssertTrue(journal.isEmpty)
    do {
      try await first.acknowledge(1)
      XCTFail("Cannot acknowledge an unexported record")
    } catch { XCTAssertEqual(error as? WhatsAppFailure, .invalid) }
    let competing = WhatsAppNativeSession(executable: executable)
    do {
      try await competing.open(directory: directory, key: key)
      XCTFail("One protocol owner only")
    } catch { XCTAssertEqual(error as? WhatsAppFailure, .owned) }
    try await first.close()
    let before = try Data(contentsOf: directory.appendingPathComponent("session.db"))
    XCTAssertFalse(before.starts(with: Data("SQLite format 3".utf8)))
    let second = WhatsAppNativeSession(executable: executable)
    try await second.open(directory: directory, key: key)
    let reopened = try await second.status()
    XCTAssertEqual(reopened.state, "offline")
    try await second.close()
    do {
      _ = try await first.status()
      XCTFail("Closed actor cannot call old worker")
    } catch { XCTAssertEqual(error as? WhatsAppFailure, .closed) }
  }
}

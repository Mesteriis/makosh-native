import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MakoshCore
import UniformTypeIdentifiers
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppAvatarTests: XCTestCase {
  func testConcurrentCacheOwnerCannotBypassBudget() async throws {
    let root = avatarTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = AvatarTestDescriptors()
    let scope = WhatsAppAvatarScope(accountID: UUID(), jid: "owner@lid")
    let service = WhatsAppAvatars(
      root: root, http: AvatarTestHTTP(data: try avatarJPEG()),
      keyProvider: avatarTestKey, descriptor: { await source.get($0) })
    _ = try await service.image(scope: scope)
    let directory = root.appendingPathComponent(scope.accountID.uuidString.lowercased())
    let cacheFiles = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "bin" }
    let before = try cacheFiles.map { try Data(contentsOf: $0) }
    let lock = directory.appendingPathComponent(".lock")
    var fd = Darwin.open(
      lock.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    guard fd >= 0 else { return }
    defer { if fd >= 0 { Darwin.close(fd) } }
    do {
      _ = try await service.image(scope: scope, refresh: true)
      XCTFail("Another cache owner must block admission")
    } catch {}
    XCTAssertEqual(
      try cacheFiles.map { try Data(contentsOf: $0) }, before,
      "A denied cache admission must not write before failing")
    XCTAssertEqual(Darwin.close(fd), 0)
    fd = -1
    let retried = try await service.image(scope: scope, refresh: true)
    XCTAssertNotNil(retried)
  }

  func testAvatarNeverWritesS3OrPGBytes() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let repository = WhatsAppRepository(
      configuration: .init(
        connectionString: connection,
        schema: "qa_whatsapp_" + suffix, archiveSchema: "qa_whatsapp_archive_" + suffix),
      keyProvider: { _, _ in Data(repeating: 0x58, count: 32) })
    let account = WhatsAppAccount(name: "Avatar isolation")
    let other = WhatsAppAccount(name: "Other avatar account")
    try await repository.saveAccount(account)
    try await repository.saveAccount(other)
    let a = try await repository.avatarCacheKey(accountID: account.id)
    let b = try await repository.avatarCacheKey(accountID: other.id)
    XCTAssertNotEqual(a, b)
    let message = waRichMessage(kind: "text", text: "Permanent source")
    try await repository.ingest(
      [.init(sequence: 1, message: message, history: true, observed: 1)], accountID: account.id)
    let before = try await repository.avatarStorageCountsForTests()
    let retained = try await repository.messages(
      accountID: account.id, chat: message.chat, before: nil)
    let root = avatarTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = AvatarTestDescriptors()
    let service = WhatsAppAvatars(
      root: root, http: AvatarTestHTTP(data: try avatarJPEG()),
      keyProvider: { try await repository.avatarCacheKey(accountID: $0) },
      descriptor: { await source.get($0) })
    let image = try await service.image(scope: .init(accountID: account.id, jid: message.chat))
    XCTAssertNotNil(image)
    let after = try await repository.avatarStorageCountsForTests()
    let unchanged = try await repository.messages(
      accountID: account.id, chat: message.chat, before: nil)
    XCTAssertEqual(before, after)
    XCTAssertEqual(retained, unchanged)
    XCTAssertEqual(after.prefix(2), [0, 0])
  }
  func testAvatarIsolationAndLateCompletion() async throws {
    let root = avatarTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let http = AvatarTestHTTP(data: try avatarJPEG())
    let source = AvatarTestDescriptors()
    let first = WhatsAppAvatarScope(accountID: UUID(), jid: "same@lid")
    let second = WhatsAppAvatarScope(accountID: UUID(), jid: "same@lid")
    let service = WhatsAppAvatars(
      root: root, http: http, keyProvider: avatarTestKey,
      descriptor: { await source.get($0) })
    let a = try await service.image(scope: first)
    let b = try await service.image(scope: second)
    XCTAssertNotNil(a)
    XCTAssertNotNil(b)
    XCTAssertNotEqual(a?.pictureID, b?.pictureID)
    await http.setSuspended(true)
    let task = Task { try await service.image(scope: first, refresh: true) }
    for _ in 0..<100 where !(await http.isWaiting()) { try await Task.sleep(for: .milliseconds(2)) }
    let waiting = await http.isWaitingValue()
    XCTAssertTrue(waiting)
    await service.invalidate(scope: first)
    await http.release()
    do {
      _ = try await task.value
      XCTFail("Invalidated avatar must not publish")
    } catch {}
    let retainedSecond = try await service.image(scope: second)
    XCTAssertEqual(retainedSecond, b)
    await service.close()
  }

  func testHTTPSHostRedirectAndSizeFailClosed() async throws {
    for raw in [
      "http://pps.whatsapp.net/a", "https://evil.test/a", "https://pps.whatsapp.net.evil.test/a",
      "https://user:pass@pps.whatsapp.net/a", "https://pps.whatsapp.net:444/a",
      "https://pps.whatsapp.net./a",
    ] {
      XCTAssertFalse(WhatsAppAvatarHTTP.accepts(URL(string: raw)!))
    }
    XCTAssertTrue(WhatsAppAvatarHTTP.accepts(URL(string: "https://media.pps.whatsapp.net/a")!))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AvatarURLProtocol.self]
    let http = WhatsAppAvatarHTTP(configuration: config)
    for path in ["redirect", "large"] {
      do {
        _ = try await http.fetch(
          URL(string: "https://pps.whatsapp.net/" + path)!, maximumBytes: 16, timeout: 20)
        XCTFail("Redirect and oversized response must fail closed")
      } catch {}
    }
    let bytes = try await http.fetch(
      URL(string: "https://pps.whatsapp.net/ok")!, maximumBytes: 16, timeout: 20)
    XCTAssertEqual(bytes, Data("avatar".utf8))
  }

  func testMissingPhotoDoesNotLoopRequests() async throws {
    let root = avatarTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = AvatarTestDescriptors(missing: true)
    let service = WhatsAppAvatars(
      root: root, http: AvatarTestHTTP(data: Data()), keyProvider: avatarTestKey,
      descriptor: { await source.get($0) })
    let scope = WhatsAppAvatarScope(accountID: UUID(), jid: "missing@lid")
    for _ in 0..<8 {
      let value = try await service.image(scope: scope)
      XCTAssertNil(value)
    }
    let count = await source.count
    XCTAssertEqual(count, 1)
    _ = try await service.image(scope: scope, refresh: true)
    let refreshed = await source.count
    XCTAssertEqual(refreshed, 2)
  }

  func testEncryptedCacheReopenAndBoundedEviction() async throws {
    let root = avatarTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try avatarJPEG()
    let http = AvatarTestHTTP(data: try avatarJPEG())
    let source = AvatarTestDescriptors()
    let scope = WhatsAppAvatarScope(accountID: UUID(), jid: "private@lid")
    let service = WhatsAppAvatars(
      root: root, http: http, keyProvider: avatarTestKey,
      descriptor: { await source.get($0) }, maximumCacheBytes: 3000)
    let first = try await service.image(scope: scope)
    XCTAssertNotNil(first)
    await service.close()
    let reopened = WhatsAppAvatars(
      root: root, http: http, keyProvider: avatarTestKey,
      descriptor: { await source.get($0) }, maximumCacheBytes: 3000)
    let next = try await reopened.image(scope: scope)
    XCTAssertEqual(next, first)
    let calls = await source.count
    XCTAssertEqual(calls, 1)
    for i in 0..<12 {
      _ = try await reopened.image(scope: .init(accountID: scope.accountID, jid: "p\(i)@lid"))
    }
    let files =
      (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?
      .allObjects as? [URL] ?? [])
      .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    let payloads = try files.map { try Data(contentsOf: $0) }
    XCTAssertFalse(payloads.isEmpty)
    XCTAssertLessThanOrEqual(payloads.reduce(0) { $0 + $1.count }, 3000)
    XCTAssertTrue(
      payloads.allSatisfy {
        $0.range(of: bytes) == nil && $0.range(of: Data("private@lid".utf8)) == nil
      })
    let denied = WhatsAppAvatars(
      root: root, http: http, keyProvider: { _ in throw WhatsAppFailure.key },
      descriptor: { await source.get($0) })
    do {
      _ = try await denied.image(scope: scope)
      XCTFail("Missing key must preserve cache and fail")
    } catch {}
    XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }

  func testImageLimitsAndTwoConcurrentPreparations() async throws {
    let root = avatarTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let http = AvatarTestHTTP(data: try avatarJPEG(width: 1024, height: 512))
    let source = AvatarTestDescriptors()
    let service = WhatsAppAvatars(
      root: root, http: http, keyProvider: avatarTestKey, descriptor: { await source.get($0) })
    let account = UUID()
    try await withThrowingTaskGroup(of: WhatsAppAvatarImage?.self) { group in
      for i in 0..<6 {
        group.addTask {
          try await service.image(scope: .init(accountID: account, jid: "peer\(i)@lid"))
        }
      }
      for try await image in group {
        XCTAssertEqual(image?.width, 512)
        XCTAssertEqual(image?.height, 256)
      }
    }
    let peak = await http.maximumConcurrent
    let limits = await http.limits
    XCTAssertEqual(peak, 2)
    XCTAssertEqual(limits, [4 * 1024 * 1024, 20])
    await http.setData(Data(repeating: 1, count: 4 * 1024 * 1024 + 1))
    do {
      _ = try await service.image(scope: .init(accountID: account, jid: "oversized@lid"))
      XCTFail("Oversized bytes")
    } catch {}
    await http.setData(try avatarJPEG(width: 4097, height: 4096))
    do {
      _ = try await service.image(scope: .init(accountID: account, jid: "pixels@lid"))
      XCTFail("Over16MP")
    } catch {}
  }
}

extension WhatsAppRepository {
  fileprivate func avatarStorageCountsForTests() throws -> [Int] {
    let db = try db()
    return try [db.filesTable, db.outboxTable, db.messagesTable].map { table in
      Int(try db.query("SELECT count(*) FROM " + table).first?.first ?? "") ?? -1
    }
  }
}

private func avatarTemporaryRoot() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("wa-avatar-" + UUID().uuidString)
}
private func avatarTestKey(_ account: UUID) async throws -> Data {
  Data(SHA256.hash(data: Data(account.uuidString.utf8)))
}
private actor AvatarTestDescriptors {
  var count = 0
  let missing: Bool
  init(missing: Bool = false) { self.missing = missing }
  func get(_ scope: WhatsAppAvatarScope) -> WhatsAppAvatarDescriptor? {
    count += 1
    return missing
      ? nil
      : .init(
        pictureID: scope.accountID.uuidString + scope.jid,
        url: URL(string: "https://pps.whatsapp.net/avatar")!)
  }
}
private actor AvatarTestHTTP: WhatsAppAvatarFetching {
  var data: Data, maximumConcurrent = 0, limits: [Int] = [], concurrent = 0, suspended = false
  var waiting: CheckedContinuation<Void, Never>?
  init(data: Data) { self.data = data }
  func setData(_ data: Data) { self.data = data }
  func setSuspended(_ value: Bool) { suspended = value }
  func isWaiting() -> Bool { waiting != nil }
  func isWaitingValue() -> Bool { waiting != nil }
  func release() {
    suspended = false
    waiting?.resume()
    waiting = nil
  }
  func fetch(_ url: URL, maximumBytes: Int, timeout: TimeInterval) async throws -> Data {
    concurrent += 1
    maximumConcurrent = max(maximumConcurrent, concurrent)
    limits = [maximumBytes, Int(timeout)]
    defer { concurrent -= 1 }
    if suspended {
      await withCheckedContinuation { waiting = $0 }
    } else {
      try await Task.sleep(for: .milliseconds(15))
    }
    return data
  }
}
func avatarJPEG(width: Int = 48, height: Int = 24) throws -> Data {
  let context = try XCTUnwrap(
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = try XCTUnwrap(context.makeImage())
  let data = NSMutableData()
  let destination = try XCTUnwrap(
    CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  XCTAssertTrue(CGImageDestinationFinalize(destination))
  return data as Data
}
private final class AvatarURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.lastPathComponent
    let status = path == "redirect" ? 302 : 200
    let data = path == "large" ? Data(repeating: 1, count: 17) : Data("avatar".utf8)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Location": "https://evil.test/avatar", "Content-Length": String(data.count)])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

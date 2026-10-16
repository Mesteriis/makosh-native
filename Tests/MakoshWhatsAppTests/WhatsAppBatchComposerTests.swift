import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

@MainActor final class WhatsAppBatchComposerTests: XCTestCase {
  func testSendWaitsForCompleteAttachmentPreparation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wa-review-batch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let urls = try (0..<2).map { n -> URL in
      let url = root.appendingPathComponent("f-\(n).txt")
      try Data("test".utf8).write(to: url)
      return url
    }
    let account = UUID()
    let service = BatchComposerService(suspendPreparation: 2)
    let model = WhatsAppComposerModel(worker: service, synthetic: true)
    model.setContext(account: account, chat: "peer@lid")
    model.text = "caption"
    let preparation = Task {
      await model.attach(urls, asFiles: true, targetAccount: account, targetChat: "peer@lid")
    }
    for _ in 0..<100 where !(await service.waitingPreparation()) {
      try await Task.sleep(for: .milliseconds(2))
    }
    let held = await service.waitingPreparation()
    XCTAssertTrue(held)
    XCTAssertEqual(model.attachments.count, 1)
    await model.send()
    let sent = await service.singleSends
    XCTAssertTrue(sent.isEmpty, "Return must not admit a prepared prefix")
    XCTAssertEqual(model.text, "caption")
    XCTAssertEqual(model.attachments.count, 1)
    await service.completePreparation()
    await preparation.value
    XCTAssertEqual(model.attachments.map(\.name), ["f-0.txt", "f-1.txt"])
    let send = Task { await model.send() }
    for _ in 0..<100 where !(await service.waitingBatch()) {
      try await Task.sleep(for: .milliseconds(2))
    }
    await service.completeBatch()
    await send.value
    XCTAssertTrue(model.attachments.isEmpty)
  }
  func testLateBatchAdmissionDoesNotClearNewDraft() async throws {
    let service = BatchComposerService()
    let account = UUID()
    let model = WhatsAppComposerModel(worker: service, synthetic: true)
    model.setContext(account: account, chat: "peer@lid")
    model.text = "old caption"
    model.attachments = (0..<2).map {
      .init(
        id: UUID(), accountID: account, chat: "peer@lid", name: "f\($0)", kind: "document",
        mime: "text/plain", size: 1)
    }
    let sending = Task { await model.send() }
    for _ in 0..<100 where !(await service.waitingBatch()) {
      try await Task.sleep(for: .milliseconds(2))
    }
    let waiting = await service.waitingBatch()
    XCTAssertTrue(waiting)
    model.text = "new caption"
    model.attachments.removeLast()
    await service.completeBatch()
    await sending.value
    XCTAssertEqual(model.text, "new caption")
    XCTAssertEqual(model.attachments.count, 1)
    XCTAssertFalse(model.sending)
  }
  func testMultiSelectionOrderedAndCancellationPreservesPrepared() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wa-compose-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let urls = try (0..<3).map { i -> URL in
      let url = root.appendingPathComponent("file-\(i).txt")
      try Data("file-\(i)".utf8).write(to: url)
      return url
    }
    let account = UUID()
    let service = BatchComposerService(suspendPreparation: 2)
    let model = WhatsAppComposerModel(worker: service, synthetic: true)
    model.setContext(account: account, chat: "peer@lid")
    let preparing = Task {
      await model.attach(urls, asFiles: true, targetAccount: account, targetChat: "peer@lid")
    }
    for _ in 0..<100 where !(await service.waitingPreparation()) {
      try await Task.sleep(for: .milliseconds(2))
    }
    let waiting = await service.waitingPreparation()
    XCTAssertTrue(waiting)
    XCTAssertEqual(model.attachments.map(\.name), ["file-0.txt"])
    model.cancelPreparation()
    await service.completePreparation()
    await preparing.value
    XCTAssertEqual(model.attachments.map(\.name), ["file-0.txt"])
    let count = await service.prepareCount
    XCTAssertEqual(count, 2)
    XCTAssertFalse(model.preparing)
    await model.attach(
      Array(urls.dropFirst()), asFiles: true, targetAccount: account, targetChat: "peer@lid")
    XCTAssertEqual(model.attachments.map(\.name), ["file-0.txt", "file-1.txt", "file-2.txt"])
    model.moveAttachment(from: 2, to: 0)
    XCTAssertEqual(model.attachments.map(\.name), ["file-2.txt", "file-0.txt", "file-1.txt"])
    let removedID = try XCTUnwrap(model.attachments.dropFirst().first?.id)
    model.removeAttachment(id: removedID)
    XCTAssertEqual(model.attachments.map(\.name), ["file-2.txt", "file-1.txt"])
  }
  func testOverLimitSelectionIsRejectedBeforeAnyPreparation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wa-compose-limit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("one.txt")
    try Data("x".utf8).write(to: url)
    let service = BatchComposerService()
    let account = UUID()
    let actual = WhatsAppComposerModel(worker: service, synthetic: true)
    actual.setContext(account: account, chat: "peer@lid")
    await actual.attach(
      Array(repeating: url, count: 11), asFiles: true, targetAccount: account,
      targetChat: "peer@lid")
    let calls = await service.prepareCount
    XCTAssertEqual(calls, 0)
    XCTAssertTrue(actual.attachments.isEmpty)
    XCTAssertNotNil(actual.error)
  }
  func testLargeFileAndSymlinkAreRejectedBeforePreparation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wa-compose-files-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let large = root.appendingPathComponent("large.bin")
    XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: 100 * 1024 * 1024 + 1)
    try handle.close()
    let regular = root.appendingPathComponent("regular.txt")
    try Data("safe".utf8).write(to: regular)
    let link = root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
    let account = UUID()
    let service = BatchComposerService()
    let model = WhatsAppComposerModel(worker: service, synthetic: true)
    model.setContext(account: account, chat: "peer@lid")
    for url in [large, link] {
      await model.attach([url], asFiles: true, targetAccount: account, targetChat: "peer@lid")
      XCTAssertNotNil(model.error)
      XCTAssertTrue(model.attachments.isEmpty)
    }
    let calls = await service.prepareCount
    XCTAssertEqual(calls, 0)
  }
  func testLatePreparedFilesStayWithOldContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wa-compose-scope-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let urls = try (0..<2).map { i -> URL in
      let url = root.appendingPathComponent("scope-\(i).txt")
      try Data("scope".utf8).write(to: url)
      return url
    }
    let a = UUID()
    let b = UUID()
    let service = BatchComposerService(suspendPreparation: 1)
    let model = WhatsAppComposerModel(worker: service, synthetic: true)
    model.setContext(account: a, chat: "peer@lid")
    model.text = "First draft"
    let preparing = Task {
      await model.attach(urls, asFiles: true, targetAccount: a, targetChat: "peer@lid")
    }
    for _ in 0..<100 where !(await service.waitingPreparation()) {
      try await Task.sleep(for: .milliseconds(2))
    }
    let waiting = await service.waitingPreparation()
    XCTAssertTrue(waiting)
    model.setContext(account: b, chat: "peer@lid")
    model.text = "Second draft"
    await service.completePreparation()
    await preparing.value
    XCTAssertTrue(model.attachments.isEmpty)
    XCTAssertEqual(model.text, "Second draft")
    XCTAssertFalse(model.preparing)
    model.setContext(account: a, chat: "peer@lid")
    XCTAssertEqual(model.text, "First draft")
    XCTAssertEqual(model.attachments.map(\.name), ["scope-0.txt", "scope-1.txt"])
  }
}
private actor BatchComposerService: WhatsAppServing {
  let compose = WhatsAppComposeTestStore()
  func composeDraft(accountID: UUID, chat: String) async -> WhatsAppComposeDraft? {
    await compose.read(account: accountID, chat: chat)
  }
  func saveComposeDraft(_ draft: WhatsAppComposeDraft, expectedRevision: UInt64?) async throws
    -> WhatsAppComposeDraft
  { try await compose.save(draft, expected: expectedRevision) }

  var singleSends: [WhatsAppOutgoingContent] = []
  func send(accountID: UUID, chat: String, content: WhatsAppOutgoingContent) -> WhatsAppOutgoing {
    singleSends.append(content)
    return .init(
      id: UUID(), accountID: accountID, chat: chat, content: content, created: Date(),
      state: .prepared)
  }
  private var pending: CheckedContinuation<WhatsAppBatchSnapshot, Error>?
  private var request: (UUID, String, WhatsAppOutgoingContent)?
  private var preparation: CheckedContinuation<Void, Never>?
  private let suspendPreparation: Int?
  private(set) var prepareCount = 0
  init(suspendPreparation: Int? = nil) { self.suspendPreparation = suspendPreparation }
  func waitingBatch() -> Bool { pending != nil }
  func waitingPreparation() -> Bool { preparation != nil }
  func completePreparation() {
    preparation?.resume()
    preparation = nil
  }
  func prepareFile(accountID: UUID, chat: String, file: URL, kind: String, mime: String)
    async throws -> WhatsAppPreparedFile
  {
    prepareCount += 1
    if prepareCount == suspendPreparation { await withCheckedContinuation { preparation = $0 } }
    return .init(
      id: UUID(), accountID: accountID, chat: chat, name: file.lastPathComponent, kind: kind,
      mime: mime, size: 1)
  }
  func sendBatch(accountID: UUID, chat: String, content: WhatsAppOutgoingContent) async throws
    -> WhatsAppBatchSnapshot
  {
    request = (accountID, chat, content)
    return try await withCheckedThrowingContinuation { pending = $0 }
  }
  func completeBatch() {
    guard let (account, chat, content) = request, let pending else { return }
    let batchID = UUID()
    let refs = content.files.enumerated().map {
      WhatsAppOutgoingBatch.Child(
        index: $0.offset, outgoingID: UUID(), reservedAttemptID: UUID(), fileID: $0.element)
    }
    let batch = WhatsAppOutgoingBatch(
      id: batchID, accountID: account, chat: chat, created: Date(), orderedChildren: refs)
    let children = refs.map {
      WhatsAppOutgoing(
        id: $0.outgoingID, accountID: account, chat: chat,
        content: .init(text: $0.index == 0 ? content.text : "", files: [$0.fileID]),
        created: Date(),
        attemptID: $0.reservedAttemptID, state: .prepared, batchID: batchID)
    }
    pending.resume(returning: .init(batch: batch, children: children))
    self.pending = nil
    request = nil
  }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    .init(accountID: accountID, status: .init(), chats: [])
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) -> [WhatsAppMessage] { [] }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func outgoing(accountID: UUID) -> [WhatsAppOutgoing] { [] }
  func shutdown() {}
}

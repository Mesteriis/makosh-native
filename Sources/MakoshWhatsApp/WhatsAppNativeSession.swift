import Darwin
import Foundation

public protocol WhatsAppTransport: Sendable {
  func connect() async throws
  func disconnect() async throws
  func status() async throws -> WhatsAppConnectionStatus
  func chats(before: WhatsAppCursor?) async throws -> [WhatsAppChat]
  func journal() async throws -> [WhatsAppJournalEntry]
  func acknowledge(_ sequence: Int64) async throws
  func close() async throws
  func callMedia(_ request: WhatsAppCallExchange) async throws -> WhatsAppCallOutput
  func perform(chat: String, action: WhatsAppAction) async throws -> WhatsAppMutationResult
}
private struct NativeRequest: Encodable {
  let version = 1
  let command: String
  var before: WhatsAppCursor?
  var sequence: Int64?
  var chat: String?
  var action: WhatsAppAction?
  var ticket: String?
  var media: WhatsAppCallExchange?
  let limit = 100
}
/// The blocking pipe and owned child are confined to this service actor.
/// No Rust library or protocol type is linked into the UI process.
public actor WhatsAppNativeSession: WhatsAppTransport {
  private nonisolated let pipeExecutor = WhatsAppPipeExecutor()
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    pipeExecutor.asUnownedSerialExecutor()
  }
  private let executable: URL
  private var child: WhatsAppChild?
  public init(executable: URL) { self.executable = executable }
  public func open(directory: URL, key: Data) throws {
    guard child == nil, key.count == 32 else { throw WhatsAppFailure.invalid }
    let process = try WhatsAppChild(executable: executable)
    child = process
    do {
      struct Options: Encodable {
        let version = 1
        let directory: String
        let key: [UInt8]
      }
      _ = try rpc(op: "open", request: Options(directory: directory.path, key: Array(key)))
    } catch {
      process.stop()
      child = nil
      throw error
    }
  }
  public func connect() throws {
    _ = try rpc(op: "call", request: NativeRequest(command: "connect"))
  }
  public func disconnect() throws {
    _ = try rpc(op: "call", request: NativeRequest(command: "disconnect"))
  }
  public func status() throws -> WhatsAppConnectionStatus { try decode(.init(command: "snapshot")) }
  public func chats(before: WhatsAppCursor?) throws -> [WhatsAppChat] {
    try decode(.init(command: "chats", before: before))
  }
  public func journal() throws -> [WhatsAppJournalEntry] { try decode(.init(command: "journal")) }
  public func acknowledge(_ sequence: Int64) throws {
    _ = try rpc(op: "call", request: NativeRequest(command: "ack", sequence: sequence))
  }
  public func callMedia(_ request: WhatsAppCallExchange) throws -> WhatsAppCallOutput {
    guard request.audio.count <= 3, request.audio.allSatisfy({ $0.count == 960 }),
      request.video.count <= 256 * 1024
    else { throw WhatsAppFailure.invalid }
    return try decode(.init(command: "call_media", media: request))
  }
  public func perform(chat: String, action: WhatsAppAction) async throws -> WhatsAppMutationResult {
    do {
      var data: Data
      do {
        data = try rpc(
          op: "call", request: NativeRequest(command: "perform", chat: chat, action: action))
      } catch let error as WhatsAppFailure {
        if [.invalid, .closed, .unavailable].contains(error) { throw WhatsAppFailure.notAdmitted }
        throw error
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(60))
      while true {
        try Task.checkCancellation()
        if data == Data("null".utf8) { return .init() }
        let result: WhatsAppMutationResult
        do { result = try JSONDecoder().decode(WhatsAppMutationResult.self, from: data) } catch {
          throw WhatsAppFailure.protocolFailure
        }
        if result.pending != true { return result }
        guard ContinuousClock.now < deadline else { throw WhatsAppFailure.protocolFailure }
        try await Task.sleep(for: .milliseconds(50))
        data = try rpc(
          op: "call", request: NativeRequest(command: "command_result", ticket: action.attempt))
      }
    } catch {
      if Task.isCancelled {
        child?.stop()
        child = nil
      }
      throw error
    }
  }
  public func close() throws {
    guard let process = child else { return }
    do { _ = try rpc(op: "close", request: NativeRequest(command: "snapshot")) } catch {
      process.stop()
      child = nil
      throw error
    }
    let stopped = process.stop()
    child = nil
    guard stopped else { throw WhatsAppFailure.protocolFailure }
  }
  private func decode<T: Decodable & Sendable>(_ request: NativeRequest) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: rpc(op: "call", request: request))
    } catch let error as WhatsAppFailure { throw error } catch {
      throw WhatsAppFailure.protocolFailure
    }
  }
  private func rpc<T: Encodable>(op: String, request: T) throws -> Data {
    guard let child else { throw WhatsAppFailure.closed }
    var frame = Data("{\"op\":\"\(op)\",\"request\":".utf8)
    frame.append(try JSONEncoder().encode(request))
    frame.append(contentsOf: [125])
    defer { frame.resetBytes(in: 0..<frame.count) }
    let response: Data
    do { response = try child.exchange(frame) } catch {
      child.stop()
      self.child = nil
      throw Task.isCancelled ? CancellationError() : WhatsAppFailure.protocolFailure
    }
    guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
      object["version"] as? Int == 1, let ok = object["ok"] as? Bool
    else { throw WhatsAppFailure.protocolFailure }
    guard ok else {
      switch object["error"] as? String {
      case "owned": throw WhatsAppFailure.owned
      case "key", "key_or_storage": throw WhatsAppFailure.key
      case "busy": throw WhatsAppFailure.notAdmitted
      case "closed", "offline": throw WhatsAppFailure.closed
      case "input", "version", "command": throw WhatsAppFailure.invalid
      default: throw WhatsAppFailure.protocolFailure
      }
    }
    return try JSONSerialization.data(
      withJSONObject: object["data"] ?? NSNull(), options: [.fragmentsAllowed])
  }
}

/// Blocking framed IO has a dedicated Dispatch executor; a stalled child must
/// not occupy Swift's cooperative executor used by mail/contact service actors.
private final class WhatsAppPipeExecutor: SerialExecutor, @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.makosh.whatsapp.ipc", qos: .userInitiated)
  func enqueue(_ job: consuming ExecutorJob) {
    let unowned = UnownedJob(job)
    let executor = asUnownedSerialExecutor()
    queue.async { unowned.runSynchronously(on: executor) }
  }
  func checkIsolated() { dispatchPrecondition(condition: .onQueue(queue)) }
}

/// @unchecked is limited to private Foundation process/pipe owners. All access,
/// including teardown, is serialized by WhatsAppNativeSession's actor.
private final class WhatsAppChild: @unchecked Sendable {
  private let process = Process(), input = Pipe(), output = Pipe()
  private var pid: pid_t = 0
  private var exited = false
  init(executable: URL) throws {
    guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw WhatsAppFailure.unavailable
    }
    process.executableURL = executable
    process.arguments = []
    // Do not inherit application credentials, private paths, debug log controls
    // or dynamic-loader overrides. The worker uses its signed runtime closure.
    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      throw WhatsAppFailure.unavailable
    }
    do { try process.run() } catch { throw WhatsAppFailure.unavailable }
    pid = process.processIdentifier
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
  }
  deinit { stop() }
  @discardableResult func stop() -> Bool {
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
    guard pid > 0, !exited else { return true }
    // Foundation waitUntilExit pumps a thread-local run loop. On the
    // dedicated Dispatch executor it can miss the exit wakeup even when
    // the child has already gone. Reap only this owned child, boundedly.
    if reap() { return true }
    _ = Darwin.kill(pid, SIGTERM)
    if waitForExit() { return true }
    _ = Darwin.kill(pid, SIGKILL)
    return waitForExit()
  }
  private func reap() -> Bool {
    var status: Int32 = 0
    while true {
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid || (result < 0 && errno == ECHILD) {
        exited = true
        return true
      }
      if result < 0 && errno == EINTR { continue }
      return false
    }
  }
  private func waitForExit() -> Bool {
    let end = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    repeat {
      if reap() { return true }
      usleep(10_000)
    } while DispatchTime.now().uptimeNanoseconds < end
    return reap()
  }
  func exchange(_ bytes: Data) throws -> Data {
    guard bytes.count > 0, bytes.count <= 2 * 1024 * 1024 else { throw WhatsAppFailure.invalid }
    let deadline = DispatchTime.now().uptimeNanoseconds + 65_000_000_000
    var size = UInt32(bytes.count).bigEndian
    let prefix = withUnsafeBytes(of: &size) { Data($0) }
    try write(prefix + bytes, deadline: deadline)
    let header = try read(4, deadline: deadline)
    let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard count > 0, count <= 8 * 1024 * 1024 else { throw WhatsAppFailure.protocolFailure }
    return try read(Int(count), deadline: deadline)
  }
  private func ready(_ descriptor: Int32, events: Int16, deadline: UInt64) throws {
    while true {
      try Task.checkCancellation()
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        throw WhatsAppFailure.protocolFailure
      }
      var item = pollfd(fd: descriptor, events: events, revents: 0)
      let count = poll(&item, 1, 250)
      if count < 0 {
        if errno == EINTR { continue }
        throw WhatsAppFailure.protocolFailure
      }
      if count > 0 {
        if item.revents & events != 0 { return }
        throw WhatsAppFailure.protocolFailure
      }
    }
  }
  private func write(_ data: Data, deadline: UInt64) throws {
    var offset = 0
    let fd = input.fileHandleForWriting.fileDescriptor
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { throw WhatsAppFailure.invalid }
      while offset < data.count {
        try ready(fd, events: Int16(POLLOUT), deadline: deadline)
        let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw WhatsAppFailure.protocolFailure }
        offset += count
      }
    }
  }
  private func read(_ length: Int, deadline: UInt64) throws -> Data {
    var bytes = Data(count: length)
    var offset = 0
    let fd = output.fileHandleForReading.fileDescriptor
    try bytes.withUnsafeMutableBytes { memory in
      guard let base = memory.baseAddress else { throw WhatsAppFailure.protocolFailure }
      while offset < length {
        try ready(fd, events: Int16(POLLIN), deadline: deadline)
        let count = Darwin.read(fd, base.advanced(by: offset), length - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw WhatsAppFailure.protocolFailure }
        offset += count
      }
    }
    return bytes
  }
}

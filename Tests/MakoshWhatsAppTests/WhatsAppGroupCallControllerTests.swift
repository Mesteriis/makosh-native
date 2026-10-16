import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

private actor GroupMediaBoundary: WhatsAppCallMediaServing {
  var waiting: CheckedContinuation<Void, any Error>?, hold = false, stops = 0
  func setHold() { hold = true }
  func ready() -> Bool { waiting != nil }
  func finish() {
    waiting?.resume()
    waiting = nil
  }
  func start(selection: WhatsAppCallDeviceSelection, video: Bool) async throws {
    if hold { try await withCheckedThrowingContinuation { waiting = $0 } }
  }
  func setVideo(_ on: Bool) {}
  func setMuted(_ on: Bool) {}
  func input() async throws -> WhatsAppCallMediaInput {
    try await Task.sleep(for: .milliseconds(20))
    return .init(audio: [], video: [])
  }
  func receive(_ output: WhatsAppCallOutput) {}
  func images() -> WhatsAppCallImages { .init(local: nil, remote: nil) }
  func stop() { stops += 1 }
}
private actor GroupCallBoundary: WhatsAppServing {
  var operations: [WhatsAppAction] = [], invitation: CheckedContinuation<Void, Never>?
  var receipts: [UUID: WhatsAppOutgoing] = [:]
  var startHeld = false, startWait: CheckedContinuation<Void, Never>?
  func holdStart() { startHeld = true }
  func startWaiting() -> Bool { startWait != nil }
  func finishStart() {
    startWait?.resume()
    startWait = nil
  }
  func nextEpoch() { call.epoch += 1 }
  var call = WhatsAppCallSnapshot(
    id: "c", epoch: 7, peer: "1@g.us", state: "active", incoming: false, video: false,
    remoteVideo: false, videoRequested: false, muted: false,
    group: .init(groupJID: "1@g.us", rosterRevision: 1, participants: []))
  func perform(accountID: UUID, chat: String, action: WhatsAppAction) throws -> WhatsAppOutgoing {
    operations.append(action)
    if action.op == .callEnd, action.target.isEmpty { throw WhatsAppFailure.notAdmitted }
    return row(accountID, chat, action)
  }
  func row(_ id: UUID, _ chat: String, _ action: WhatsAppAction) -> WhatsAppOutgoing {
    var row = WhatsAppOutgoing(
      id: UUID(), accountID: id, chat: chat, content: .init(text: "", action: action),
      created: Date(), state: .sent)
    if action.op == .callGroupStart {
      row.stanza = "c"
      row.callEpoch = 7
    }
    receipts[row.id] = row
    return row
  }
  func startGroupCall(accountID: UUID, groupJID: String, participants: [String], video: Bool) async
    -> WhatsAppOutgoing
  {
    await startGroupCall(
      accountID: accountID, groupJID: groupJID, participants: participants, video: video,
      callContext: nil)
  }
  func startGroupCall(
    accountID: UUID, groupJID: String, participants: [String], video: Bool, callContext: UUID?
  ) async -> WhatsAppOutgoing {
    var action = WhatsAppAction(.callGroupStart, on: video)
    action.callContext = callContext
    action.options = participants
    operations.append(action)
    if startHeld { await withCheckedContinuation { startWait = $0 } }
    return row(accountID, groupJID, action)
  }
  func cancelAcceptedCall(accountID: UUID, outgoingID: UUID) throws {
    guard let receipt = receipts[outgoingID], receipt.stanza == call.id,
      receipt.callEpoch == call.epoch
    else { throw WhatsAppFailure.closed }
    var action = WhatsAppAction(.callEnd, target: call.id)
    action.callEpoch = call.epoch
    _ = try perform(accountID: accountID, chat: call.peer, action: action)
  }
  func inviteCallParticipant(
    accountID: UUID, callID: String, epoch: UInt64, jid: String, ringOnly: Bool
  ) async -> WhatsAppOutgoing {
    await withCheckedContinuation { invitation = $0 }
    return row(accountID, "1@g.us", .init(.callInvite, target: callID, to: jid))
  }
  func waiting() -> Bool { invitation != nil }
  func finish() {
    invitation?.resume()
    invitation = nil
  }
  func callMedia(accountID: UUID, request: WhatsAppCallExchange) -> WhatsAppCallOutput {
    .init(
      audio: [], video: nil, keyframe: false, orientation: 0,
      visibilityRevision: request.visibilityRevision)
  }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    var s = WhatsAppConnectionStatus()
    s.call = call
    return .init(accountID: accountID, status: s, chats: [])
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) -> [WhatsAppMessage] { [] }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func shutdown() {}
}
@MainActor final class WhatsAppGroupCallControllerTests: XCTestCase {
  func testEarlyEndCarriesStartContextBeforeReceipt() async throws {
    let worker = GroupCallBoundary()
    await worker.holdStart()
    let media = GroupMediaBoundary()
    let m = WhatsAppCallController(
      worker: worker, synthetic: false, permission: { _ in true }, makeMedia: { media })
    m.startGroup(
      accountID: UUID(), groupJID: "1@g.us", participants: ["a@lid", "b@lid"], video: false)
    for _ in 0..<100 {
      if await worker.startWaiting() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    await m.leave()
    let ops = await worker.operations
    let start = try XCTUnwrap(ops.first { $0.op == .callGroupStart })
    let end = try XCTUnwrap(ops.last { $0.op == .callEnd })
    XCTAssertNotNil(start.callContext)
    XCTAssertEqual(start.callContext, end.callContext)
    await worker.finishStart()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(m.call)
  }
  func testIncomingGroupAcceptCancelAndLeaveFenced() async throws {
    let worker = GroupCallBoundary()
    let media = GroupMediaBoundary()
    await media.setHold()
    let m = WhatsAppCallController(
      worker: worker, synthetic: false, permission: { _ in true }, makeMedia: { media })
    var incoming = await worker.call
    incoming.state = "ringing"
    incoming.incoming = true
    m.observe(incoming, account: UUID())
    m.accept(video: false)
    for _ in 0..<200 {
      if await media.ready() { break }
      await Task.yield()
    }
    let ready = await media.ready()
    XCTAssertTrue(ready)
    await m.leave()
    await media.finish()
    for _ in 0..<100 { await Task.yield() }
    let ops = await worker.operations
    XCTAssertFalse(ops.contains { $0.op == .callAccept })
    XCTAssertNil(m.call)
  }
  func testInviteDuringEndCannotStartNewCall() async throws {
    let worker = GroupCallBoundary()
    let media = GroupMediaBoundary()
    let m = WhatsAppCallController(
      worker: worker, synthetic: false, permission: { _ in true }, makeMedia: { media })
    m.startGroup(
      accountID: UUID(), groupJID: "1@g.us", participants: ["a@lid", "b@lid"], video: false)
    for _ in 0..<200 {
      if m.call?.id == "c" { break }
      await Task.yield()
    }
    XCTAssertEqual(m.call?.id, "c")
    let invite = Task { await m.invite(jid: "d@lid", ringOnly: false) }
    for _ in 0..<200 {
      if await worker.waiting() { break }
      await Task.yield()
    }
    await m.leave()
    await worker.finish()
    await invite.value
    XCTAssertNil(m.call)
    let ops = await worker.operations
    XCTAssertEqual(ops.filter { $0.op == .callGroupStart }.count, 1)
    XCTAssertEqual(ops.last?.callEpoch, 7)
  }
  func testDelayedPermissionDoesNotDispatchAfterLeaveAndInvalidChoice() async throws {
    let worker = GroupCallBoundary()
    let media = GroupMediaBoundary()
    var permission: CheckedContinuation<Bool, Never>?
    let m = WhatsAppCallController(
      worker: worker, synthetic: false,
      permission: { _ in await withCheckedContinuation { permission = $0 } }, makeMedia: { media })
    m.startGroup(accountID: UUID(), groupJID: "1@g.us", participants: [], video: false)
    XCTAssertNil(m.call)
    m.startGroup(
      accountID: UUID(), groupJID: "1@g.us", participants: ["a@lid", "b@lid"], video: false)
    for _ in 0..<100 {
      if permission != nil { break }
      await Task.yield()
    }
    XCTAssertNotNil(permission)
    await m.leave()
    permission?.resume(returning: true)
    for _ in 0..<100 { await Task.yield() }
    let ops = await worker.operations
    XCTAssertTrue(ops.isEmpty)
    XCTAssertNil(m.call)
  }
}
extension WhatsAppGroupCallControllerTests {
  func testLateRingingSnapshotCannotReopenAfterLeave() async throws {
    let worker = GroupCallBoundary()
    let media = GroupMediaBoundary()
    let m = WhatsAppCallController(
      worker: worker, synthetic: false, permission: { _ in true }, makeMedia: { media })
    let account = UUID()
    var incoming = await worker.call
    incoming.state = "ringing"
    incoming.incoming = true
    m.observe(incoming, account: account)
    await m.leave()
    XCTAssertNil(m.call)
    m.observe(incoming, account: account)
    XCTAssertNil(m.call)
    incoming.epoch = 8
    m.observe(incoming, account: account)
    XCTAssertEqual(m.call?.epoch, 8)
    await m.leave()
  }
}

extension WhatsAppGroupCallControllerTests {
  func testCancelAfterNativeStartBeforeReceiptEndsOnlyAcceptedCall() async throws {
    let worker = GroupCallBoundary()
    let media = GroupMediaBoundary()
    await worker.holdStart()
    let m = WhatsAppCallController(
      worker: worker, synthetic: false, permission: { _ in true }, makeMedia: { media })
    m.startGroup(
      accountID: UUID(), groupJID: "1@g.us", participants: ["a@lid", "b@lid"], video: false)
    for _ in 0..<100 {
      if await worker.startWaiting() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let ready = await worker.startWaiting()
    XCTAssertTrue(ready)
    await m.leave()
    await worker.finishStart()
    for _ in 0..<100 {
      let ops = await worker.operations
      if ops.last?.target == "c" { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let ops = await worker.operations
    XCTAssertEqual(ops.last?.op, .callEnd)
    XCTAssertEqual(ops.last?.target, "c")
    XCTAssertEqual(ops.last?.callEpoch, 7)
    XCTAssertNil(m.call)
  }
  func testCanceledStartReceiptCannotEndReusedIDInLaterEpoch() async throws {
    let worker = GroupCallBoundary()
    let media = GroupMediaBoundary()
    await worker.holdStart()
    let m = WhatsAppCallController(
      worker: worker, synthetic: false, permission: { _ in true }, makeMedia: { media })
    let account = UUID()
    m.startGroup(
      accountID: account, groupJID: "1@g.us", participants: ["a@lid", "b@lid"], video: false)
    for _ in 0..<100 {
      if await worker.startWaiting() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    await m.leave()
    await worker.nextEpoch()
    var fresh = await worker.call
    fresh.incoming = true
    fresh.state = "ringing"
    m.observe(fresh, account: account)
    await worker.finishStart()
    try await Task.sleep(for: .milliseconds(100))
    let ops = await worker.operations
    XCTAssertFalse(ops.contains { $0.op == .callEnd && $0.target == "c" })
    XCTAssertEqual(m.call?.epoch, 8)
    await m.leave()
  }
}

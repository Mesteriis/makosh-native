import AVFoundation
import Combine
import CoreGraphics
import Foundation
import MakoshWhatsApp

private final class WhatsAppCallLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var live = true
  var active: Bool { lock.withLock { live } }
  func revoke() { lock.withLock { live = false } }
}
@MainActor final class WhatsAppCallController: ObservableObject {
  @Published private(set) var call: WhatsAppCallSnapshot?
  @Published private(set) var accountID: UUID?
  @Published private(set) var images = WhatsAppCallImages(local: nil, remote: nil)
  @Published private(set) var groupImages: [WhatsAppGroupCallImage] = []
  @Published var groupPage = 0
  @Published var pinnedParticipant: String?
  let avatarCache = WhatsAppAvatarWindowCache()
  var avatarWorker: any WhatsAppServing { worker }
  @Published var error: String?
  @Published var devices = WhatsAppCallDeviceSelection()
  @Published private(set) var deviceList: WhatsAppCallDeviceList?
  private struct Run: Sendable {
    let id: UUID, account: UUID, peer: String, media: any WhatsAppCallMediaServing,
      lifetime: WhatsAppCallLifetime
    let groupMedia = WhatsAppGroupCallMedia()
    var invoked = false
    var mediaStarted = false
  }
  private let worker: any WhatsAppServing, synthetic: Bool
  private let permission: @MainActor (Bool) async -> Bool
  private let makeMedia: @Sendable () -> any WhatsAppCallMediaServing
  private var retiredCalls: [UUID: (String, UInt64)] = [:]
  private var run: Run?, pump: Task<Void, Never>?
  init(
    worker: any WhatsAppServing, synthetic: Bool,
    permission: @escaping @MainActor (Bool) async -> Bool = WhatsAppCallController.allowMedia,
    makeMedia: @escaping @Sendable () -> any WhatsAppCallMediaServing = { WhatsAppCallMedia() }
  ) {
    self.worker = worker
    self.synthetic = synthetic
    self.permission = permission
    self.makeMedia = makeMedia
  }
  isolated deinit {
    run?.lifetime.revoke()
    pump?.cancel()
    if let run {
      let worker = worker
      let call = call
      Task {
        await run.groupMedia.stop()
        await run.media.stop()
        if run.invoked {
          _ = try? await worker.perform(
            accountID: run.account, chat: run.peer,
            action: Self.scoped(.callEnd, call: call, context: run.id))
        }
      }
    }
  }
  static func allowMedia(_ video: Bool) async -> Bool {
    let types: [AVMediaType] = video ? [.audio, .video] : [.audio]
    for type in types {
      switch AVCaptureDevice.authorizationStatus(for: type) {
      case .authorized: break
      case .notDetermined:
        guard await AVCaptureDevice.requestAccess(for: type) else { return false }
      default: return false
      }
    }
    return true
  }
  #if DEBUG
    var isSyntheticPreviewAllowed: Bool { synthetic && run == nil }
    func installGroupPreview(_ value: WhatsAppCallSnapshot) {
      guard isSyntheticPreviewAllowed else { return }
      call = value
    }
    func preview() {
      guard synthetic, run == nil else { return }
      call = .init(
        id: "synthetic-preview", epoch: 0, peer: "Синтетический собеседник", state: "preview",
        incoming: false, video: true, remoteVideo: true, videoRequested: false, muted: false)
    }
  #endif
  func loadDevices() async {
    guard !synthetic, run == nil, call == nil else { return }
    let list = await WhatsAppCallMedia().devices()
    guard run == nil, call == nil else { return }
    deviceList = list
  }
  func start(accountID: UUID, peer: String, video: Bool) {
    begin(account: accountID, peer: peer, video: video, incoming: nil)
  }
  func startGroup(accountID: UUID, groupJID: String, participants: [String], video: Bool) {
    do {
      try WhatsAppGroupCallTargets.validateGroup(groupJID)
      let targets = try WhatsAppGroupCallTargets.validate(participants)
      begin(account: accountID, peer: groupJID, video: video, incoming: nil, participants: targets)
    } catch { self.error = error.localizedDescription }
  }
  func invite(jid: String, ringOnly: Bool) async {
    guard let run, let call, !call.ended, call.state == "active", !call.id.isEmpty else { return }
    do {
      _ = try await worker.inviteCallParticipant(
        accountID: run.account, callID: call.id, epoch: call.epoch, jid: jid, ringOnly: ringOnly)
      guard self.run?.id == run.id, run.lifetime.active else { return }
    } catch { if self.run?.id == run.id { self.error = error.localizedDescription } }
  }
  func leave() async { await end() }
  func setVisibleStreams(_ ids: [WhatsAppCallStreamID]) {
    guard let run, let call, ids.count <= 9 else { return }
    Task { try? await run.groupMedia.setVisibleStreams(ids, callID: call.id, epoch: call.epoch) }
  }
  private static func scoped(
    _ op: WhatsAppAction.Operation, call: WhatsAppCallSnapshot?, on: Bool = false,
    context: UUID? = nil
  ) -> WhatsAppAction {
    var action = WhatsAppAction(op, target: call?.id ?? "", on: on)
    action.callContext = context
    if let call, !call.id.isEmpty, call.epoch > 0 { action.callEpoch = call.epoch }
    return action
  }
  func accept(video: Bool) {
    guard let accountID, let call, call.incoming, call.state == "ringing" else { return }
    begin(account: accountID, peer: call.peer, video: video, incoming: call)
  }
  private func begin(
    account: UUID, peer: String, video: Bool, incoming: WhatsAppCallSnapshot?,
    participants: [String]? = nil
  ) {
    guard !synthetic, run == nil, call == nil || incoming != nil,
      !peer.hasSuffix("@g.us") || participants != nil || incoming?.group != nil
    else {
      return
    }
    let id = UUID()
    let media = makeMedia()
    let lifetime = WhatsAppCallLifetime()
    let selection = devices
    run = Run(id: id, account: account, peer: peer, media: media, lifetime: lifetime)
    accountID = account
    error = nil
    images = .init(local: nil, remote: nil)
    groupImages = []
    groupPage = 0
    pinnedParticipant = nil
    call =
      incoming
      ?? .init(
        id: "", epoch: 0, peer: peer, state: "permission", incoming: false, video: video,
        remoteVideo: false, videoRequested: false, muted: false)
    Task { [weak self] in
      guard let self else {
        await media.stop()
        return
      }
      guard await self.permission(video), self.run?.id == id, lifetime.active else {
        if self.run?.id == id {
          self.error = "Разрешите микрофон и камеру в настройках macOS."
          await self.end(sendProtocol: false)
        }
        await media.stop()
        return
      }
      var accepted: WhatsAppOutgoing?
      do {
        try await media.start(selection: selection, video: video)
        guard self.run?.id == id, lifetime.active else {
          await media.stop()
          return
        }
        self.run?.mediaStarted = true
        self.run?.invoked = true
        let operation: WhatsAppAction.Operation = incoming == nil ? .callStart : .callAccept
        if let participants {
          accepted = try await self.worker.startGroupCall(
            accountID: account, groupJID: peer, participants: participants, video: video,
            callContext: id)
        } else {
          accepted = try await self.worker.perform(
            accountID: account, chat: peer,
            action: Self.scoped(operation, call: incoming, on: video, context: id))
        }
        guard self.run?.id == id, lifetime.active else {
          await media.stop()
          if let accepted { await self.cancelAccepted(accepted, account: account) }
          return
        }
        let snapshot = try await self.worker.snapshot(accountID: account)
        guard self.run?.id == id, lifetime.active, let call = snapshot.status.call, !call.ended
        else { throw WhatsAppFailure.closed }
        guard let current = self.run, current.id == id else {
          await media.stop()
          return
        }
        self.call = call
        self.startPump(run: current, call: call)
      } catch {
        if self.run?.id == id {
          self.error = error.localizedDescription
          await self.end()
        } else {
          await media.stop()
          if let accepted { await self.cancelAccepted(accepted, account: account) }
        }
      }
    }
  }
  private func cancelAccepted(_ receipt: WhatsAppOutgoing, account: UUID) async {
    do { try await worker.cancelAcceptedCall(accountID: account, outgoingID: receipt.id) } catch {
      if !(error is CancellationError), (error as? WhatsAppFailure) != .closed, run == nil,
        call == nil
      {
        self.error = "Не удалось подтвердить завершение предыдущего звонка. Проверьте очередь."
      }
    }
  }
  func observe(_ snapshot: WhatsAppCallSnapshot?, account: UUID) {
    guard let snapshot else { return }
    if let retired = retiredCalls[account], retired.0 == snapshot.id, retired.1 >= snapshot.epoch {
      return
    }
    if let run {
      guard run.account == account, call?.id == snapshot.id || call?.id.isEmpty == true else {
        return
      }
      guard call?.id.isEmpty == true || call?.epoch == snapshot.epoch else { return }
      if let current = call?.group, let next = snapshot.group,
        next.rosterRevision < current.rosterRevision
      {
        return
      }
      call = snapshot
      if snapshot.ended { Task { await end(sendProtocol: false) } }
    } else if call == nil, snapshot.incoming, snapshot.state == "ringing", !synthetic {
      accountID = account
      call = snapshot
    } else if accountID == account, call?.id == snapshot.id, snapshot.ended {
      call = nil
      accountID = nil
    }
  }
  private func startPump(run: Run, call: WhatsAppCallSnapshot) {
    pump?.cancel()
    let worker = worker
    pump = Task.detached { [weak self] in
      do {
        var groupMode = false
        while run.lifetime.active, !Task.isCancelled {
          guard let current = await self?.pumpState(runID: run.id) else { break }
          var visibility: WhatsAppCallVisibility?
          if let roster = current.call.group {
            if !groupMode {
              groupMode = true
              await run.media.setGroupVideoMode()
            }
            try await run.groupMedia.setVisibleStreams(
              current.streams, callID: call.id, epoch: call.epoch)
            visibility = await run.groupMedia.selection()
            // Roster removal retires codecs even when the provider has no new frames.
            await run.groupMedia.receive(
              .init(audio: [], video: nil, keyframe: false, orientation: 0), callID: call.id,
              epoch: call.epoch, roster: roster)
          }
          let input = try await run.media.input()
          let output = try await worker.callMedia(
            accountID: run.account,
            request: .init(
              id: call.id, epoch: call.epoch, audio: input.audio, video: input.video,
              visibleStreams: visibility?.streams, visibilityRevision: visibility?.revision))
          guard run.lifetime.active, !Task.isCancelled else { break }
          if let roster = current.call.group {
            await run.groupMedia.receive(
              output, callID: call.id, epoch: call.epoch, roster: roster,
              expectedVisibilityRevision: visibility?.revision)
          }
          await run.media.receive(output)
          let groupImages = await run.groupMedia.images()
          let images = await run.media.images()
          await self?.publish(images, groupImages: groupImages, runID: run.id)
          try await Task.sleep(for: .milliseconds(45))
        }
      } catch { if run.lifetime.active { await self?.mediaFailed(error, runID: run.id) } }
    }
  }
  private func pumpState(runID: UUID) -> (
    call: WhatsAppCallSnapshot, streams: [WhatsAppCallStreamID]
  )? {
    guard run?.id == runID, let call, !call.ended else { return nil }
    return (
      call,
      WhatsAppGroupCallLayout(
        participants: call.group?.participants ?? [], page: groupPage, pinned: pinnedParticipant
      ).visibleStreams
    )
  }
  private func publish(
    _ images: WhatsAppCallImages, groupImages: [WhatsAppGroupCallImage], runID: UUID
  ) {
    guard run?.id == runID, run?.lifetime.active == true else { return }
    self.groupImages = call?.group == nil ? [] : groupImages
    self.images = .init(
      local: call?.video == true ? images.local : nil,
      remote: call?.remoteVideo == true ? images.remote : nil)
  }
  private func mediaFailed(_ error: Error, runID: UUID) async {
    guard run?.id == runID else { return }
    if !(error is CancellationError) { self.error = error.localizedDescription }
    await end()
  }
  func end(sendProtocol: Bool = true) async {
    let old = run
    let oldCall = call
    let account = accountID
    if let account, let oldCall, !oldCall.id.isEmpty {
      retiredCalls[account] = (oldCall.id, oldCall.epoch)
    }
    run = nil
    call = nil
    accountID = nil
    images = .init(local: nil, remote: nil)
    groupImages = []
    old?.lifetime.revoke()
    pump?.cancel()
    pump = nil
    if let old {
      await old.groupMedia.stop()
      await old.media.stop()
    }
    if sendProtocol, let account, old?.invoked == true || oldCall?.incoming == true {
      do {
        _ = try await worker.perform(
          accountID: account, chat: old?.peer ?? oldCall?.peer ?? "",
          action: Self.scoped(
            old == nil || old?.invoked == false && oldCall?.incoming == true
              ? .callReject : .callEnd, call: oldCall, context: old?.invoked == true ? old?.id : nil
          ))
      } catch { if self.run == nil, self.call == nil { self.error = error.localizedDescription } }
    }
  }
  func setMuted(_ value: Bool) async {
    guard let run, let call else { return }
    if value { await run.media.setMuted(true) }
    do {
      _ = try await worker.perform(
        accountID: run.account, chat: run.peer,
        action: Self.scoped(.callMute, call: call, on: value)
      )
      guard self.run?.id == run.id else { return }
      await run.media.setMuted(value)
      self.call?.muted = value
    } catch { if self.run?.id == run.id { self.error = error.localizedDescription } }
  }
  func setVideo(_ value: Bool) async {
    guard let run, let call else { return }
    if value, await !permission(true) {
      error = "Камера недоступна. Разрешите доступ в настройках macOS."
      return
    }
    guard self.run?.id == run.id else { return }
    do {
      try await run.media.setVideo(value)
      _ = try await worker.perform(
        accountID: run.account, chat: run.peer,
        action: Self.scoped(.callVideo, call: call, on: value))
      guard self.run?.id == run.id else { return }
      self.call?.video = value
    } catch {
      try? await run.media.setVideo(false)
      if self.run?.id == run.id { self.error = error.localizedDescription }
    }
  }
}

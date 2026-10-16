import Combine
import Foundation
import MakoshWhatsApp

@MainActor final class WhatsAppVoiceRecordingModel: ObservableObject {
  @Published private(set) var recording = false
  @Published private(set) var preparing = false
  @Published private(set) var seconds = 0
  @Published var error: String?
  private let worker: any WhatsAppServing, synthetic: Bool
  private let permission: @MainActor () async -> Bool
  private let prepared: (WhatsAppPreparedFile) -> Void
  private var capture: WhatsAppVoiceCapture?, timer: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var account: UUID?, chat: String?
  init(
    worker: any WhatsAppServing, synthetic: Bool,
    permission: @escaping @MainActor () async -> Bool = {
      await WhatsAppCallController.allowMedia(false)
    }, prepared: @escaping (WhatsAppPreparedFile) -> Void
  ) {
    self.worker = worker
    self.synthetic = synthetic
    self.permission = permission
    self.prepared = prepared
  }
  isolated deinit {
    timer?.cancel()
    if let capture { Task { await capture.cancel() } }
  }
  var canRecord: Bool { !synthetic }
  func start(account: UUID, chat: String) {
    guard !synthetic, capture == nil, !preparing else { return }
    generation &+= 1
    let token = generation
    self.account = account
    self.chat = chat
    error = nil
    let capture = WhatsAppVoiceCapture()
    self.capture = capture
    Task { [weak self] in
      let granted = await self?.permission() == true
      guard let self, self.generation == token else {
        await capture.cancel()
        return
      }
      guard granted else {
        self.capture = nil
        self.error = "Разрешите микрофон в настройках macOS."
        await capture.cancel()
        return
      }
      do {
        try await capture.start()
        guard self.generation == token else {
          await capture.cancel()
          return
        }
        self.recording = true
        self.seconds = 0
        self.timer = Task { [weak self] in
          while !Task.isCancelled {
            let status = await capture.status()
            guard self?.generation == token else { break }
            self?.seconds = status.seconds
            if status.full {
              Task { [weak self] in await self?.finish() }
              break
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
          }
        }
      } catch {
        if self.generation == token {
          self.error = error.localizedDescription
          self.capture = nil
        }
      }
    }
  }
  func finish() async {
    guard let capture, let account, let chat, !preparing else { return }
    let token = generation
    self.capture = nil
    recording = false
    preparing = true
    timer?.cancel()
    timer = nil
    defer { if generation == token { preparing = false } }
    do {
      let samples = try await capture.finish()
      guard generation == token else { return }
      let file = try await worker.prepareVoice(accountID: account, chat: chat, samples: samples)
      if generation == token { prepared(file) }
    } catch { if generation == token { self.error = error.localizedDescription } }
  }
  func cancel() {
    generation &+= 1
    timer?.cancel()
    timer = nil
    let old = capture
    capture = nil
    recording = false
    preparing = false
    seconds = 0
    error = nil
    if let old { Task { await old.cancel() } }
  }
}

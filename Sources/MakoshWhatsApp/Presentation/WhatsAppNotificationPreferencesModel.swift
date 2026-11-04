import Combine
import Foundation

@MainActor package final class WhatsAppNotificationPreferencesModel: ObservableObject {
  @Published package var rule = WhatsAppNotificationRule()
  @Published package private(set) var loaded = false
  @Published package private(set) var busy = false
  @Published package var notice: String?
  private let worker: any WhatsAppServing
  private var account: UUID?
  private var generation: UInt64 = 0
  package init(worker: any WhatsAppServing) { self.worker = worker }
  package func reset(_ account: UUID?) {
    generation &+= 1
    self.account = account
    rule = .init()
    loaded = false
    busy = false
    notice = nil
  }
  package func load(expectedAccount: UUID?) async {
    guard account == expectedAccount else { return }
    let token = generation
    busy = true
    defer { if generation == token { busy = false } }
    do {
      let value = try await worker.savedNotificationRule(accountID: expectedAccount, chat: nil)
      guard generation == token, !Task.isCancelled else { return }
      rule = value
      loaded = true
    } catch { if generation == token { notice = error.localizedDescription } }
  }
  package func save(expectedAccount: UUID?) async {
    guard loaded, !busy, account == expectedAccount else { return }
    let token = generation
    let value = rule
    busy = true
    defer { if generation == token { busy = false } }
    do {
      try await worker.setNotificationRule(value, accountID: expectedAccount, chat: nil)
      if generation == token { notice = "Настройки сохранены" }
    } catch { if generation == token { notice = error.localizedDescription } }
  }
}

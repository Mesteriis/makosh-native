import Combine
import Foundation

@MainActor package final class WhatsAppActionsModel: ObservableObject {
  @Published package private(set) var info: WhatsAppPeerInfo?
  @Published package var rule = WhatsAppNotificationRule()
  @Published package var saving = false
  @Published package private(set) var busy = false
  @Published package private(set) var settingsLoaded = false
  @Published package var error: String?
  @Published package private(set) var notice: String?
  private let worker: any WhatsAppServing
  private var account: UUID?, chat: String?
  private var generation: UInt64 = 0
  package init(worker: any WhatsAppServing) { self.worker = worker }
  package func setContext(account: UUID?, chat: String?) {
    generation &+= 1
    self.account = account
    self.chat = chat
    settingsLoaded = false
    info = nil
    rule = .init()
    saving = false
    busy = false
    error = nil
    notice = nil
  }
  package func contextMatches(account: UUID, chat: String) -> Bool {
    self.account == account && self.chat?.utf8.elementsEqual(chat.utf8) == true
  }
  package func loadSettings() async {
    guard let account, let chat else { return }
    guard !busy else { return }
    let token = generation
    busy = true
    settingsLoaded = false
    defer { if generation == token { busy = false } }
    do {
      let r = try await worker.savedNotificationRule(accountID: account, chat: chat)
      let s = try await worker.savingFiles(accountID: account, chat: chat)
      guard generation == token, !Task.isCancelled else { return }
      rule = r
      saving = s
      settingsLoaded = true
    } catch { if generation == token { self.error = error.localizedDescription } }
  }
  package func saveSettings() async {
    guard settingsLoaded, let account, let chat, !busy else { return }
    let token = generation
    let r = rule
    let s = saving
    busy = true
    defer { if generation == token { busy = false } }
    do {
      try await worker.setNotificationRule(r, accountID: account, chat: chat)
      try await worker.setSavingFiles(accountID: account, chat: chat, enabled: s)
      if generation == token { notice = "Настройки сохранены" }
    } catch { if generation == token { self.error = error.localizedDescription } }
  }
  package func inspect(_ operation: WhatsAppAction.Operation) async {
    guard let account, let chat, !busy else { return }
    let token = generation
    busy = true
    defer { if generation == token { busy = false } }
    do {
      let value = try await worker.info(accountID: account, chat: chat, operation: operation)
      if generation == token { info = value }
    } catch { if generation == token { self.error = error.localizedDescription } }
  }
  @discardableResult package func perform(
    _ action: WhatsAppAction, expectedAccount: UUID, expectedChat: String
  ) async -> WhatsAppOutgoing? {
    guard contextMatches(account: expectedAccount, chat: expectedChat) else {
      error = "Диалог изменился. Откройте действие заново."
      return nil
    }
    guard let account, let chat, !busy else { return nil }
    let token = generation
    busy = true
    error = nil
    notice = nil
    defer { if generation == token { busy = false } }
    do {
      let value = try await worker.perform(accountID: account, chat: chat, action: action)
      if generation == token {
        notice =
          value.state == .prepared
          ? "Тестовая очередь · команда не отправлена" : "Команда передана ядру"
        if let info = value.info { self.info = info }
      }
      return value
    } catch {
      if generation == token { self.error = error.localizedDescription }
      return nil
    }
  }
  package func download(_ message: WhatsAppMessage, expectedAccount: UUID) async -> WhatsAppFileLease? {
    guard contextMatches(account: expectedAccount, chat: message.chat), let account, !busy else {
      return nil
    }
    let token = generation
    busy = true
    defer { if generation == token { busy = false } }
    do {
      let value = try await worker.download(accountID: account, chat: message.chat, id: message.id)
      guard generation == token else {
        value.remove()
        return nil
      }
      return value
    } catch {
      if generation == token { self.error = error.localizedDescription }
      return nil
    }
  }
}

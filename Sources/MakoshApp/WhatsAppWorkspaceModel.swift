import CoreImage
import Foundation
import MakoshCore
import MakoshWhatsApp
import SwiftUI

@MainActor final class WhatsAppWorkspaceModel: ObservableObject {
  @Published private(set) var accounts: [WhatsAppAccount] = []
  @Published private(set) var selectedAccountID: UUID?
  @Published private(set) var selectedChatID: String?
  @Published private(set) var chats: [WhatsAppChat] = []
  @Published private(set) var messages: [WhatsAppMessage] = []
  @Published private(set) var status = WhatsAppConnectionStatus()
  @Published private(set) var qrImage: Data?
  @Published private(set) var busy = false
  @Published private(set) var historyBusy = false
  @Published private(set) var hasOlder = false
  @Published var error: String?
  @Published private(set) var notificationEvents: [WhatsAppNotificationEvent] = []
  @Published private(set) var notificationActivation: UUID?
  @Published private(set) var notificationError: String?
  @Published private(set) var archiveError: String?
  var notificationWorker: any WhatsAppServing { worker }
  let isSynthetic: Bool
  let composer: WhatsAppComposerModel
  let actions: WhatsAppActionsModel
  let calls: WhatsAppCallController
  let avatarCache = WhatsAppAvatarWindowCache()
  var composerText: String {
    get { composer.text }
    set { composer.text = newValue }
  }
  var sending: Bool { composer.sending }
  private let worker: any WhatsAppServing
  private let polling: Bool
  private var loaded = false, loading = false, refreshing = false, syntheticPairing = false
  private var accountGeneration: UInt64 = 0, chatGeneration: UInt64 = 0
  private var pollTask: Task<Void, Never>?, operationTask: Task<Void, Never>?
  init(synthetic: Bool = false) {
    isSynthetic = synthetic
    let service = WhatsAppWorker(synthetic: synthetic)
    worker = service
    composer = .init(worker: service, synthetic: synthetic)
    actions = .init(worker: service)
    calls = .init(worker: service, synthetic: synthetic)
    polling = true
  }
  init(worker: any WhatsAppServing, polling: Bool,synthetic:Bool=false) {
    self.worker = worker
    self.polling = polling
    isSynthetic = synthetic
    composer = .init(worker: worker, synthetic: synthetic)
    actions = .init(worker: worker)
    calls = .init(worker: worker, synthetic: synthetic)
  }
  func sendCompose() async {
    await composer.send()
    await refresh()
  }
  deinit {
    pollTask?.cancel()
    operationTask?.cancel()
    let worker = worker
    let composer=composer
    Task { @MainActor in await composer.flushDrafts();await worker.shutdown() }
  }
  var selectedChat: WhatsAppChat? { chats.first { $0.id == selectedChatID } }
  func load(configuration: ContactWorkspaceConfiguration) async {
    guard !loaded, !loading else { return }
    loading = true
    defer { loading = false }
    do {
      accounts = try await worker.load(configuration: configuration)
      loaded = true
      if let first = accounts.first { await selectAccount(first.id) }
      if polling {
        pollTask = Task { [weak self] in
          while !Task.isCancelled {
            await self?.refresh()
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
          }
        }
      }
    } catch { report(error) }
  }
  func selectAccount(_ id: UUID) async {
    guard accounts.contains(where: { $0.id == id }) else { return }
    accountGeneration &+= 1
    chatGeneration &+= 1
    operationTask?.cancel()
    selectedAccountID = id
    selectedChatID = nil
    chats = []
    messages = []
    status = .init()
    qrImage = nil
    composer.setContext(account: id, chat: nil)
    actions.setContext(account: id, chat: nil)
    syntheticPairing = false
    busy = false
    historyBusy = false
    hasOlder = false
    error = nil
    let generation = accountGeneration
    do {
      let value = try await worker.snapshot(accountID: id)
      guard selectedAccountID == id, accountGeneration == generation else { return }
      chats = WhatsAppChatListProjection.visible(value.chats)
      await publishStatus(value.status, account: id, generation: generation)
    } catch { if accountGeneration == generation { report(error) } }
  }
  func selectChat(_ id: String?) async {
    guard id != "status@broadcast" else { return }
    chatGeneration &+= 1
    let generation = chatGeneration
    let account = selectedAccountID
    selectedChatID = id
    messages = []
    hasOlder = false
    historyBusy = false
    composer.setContext(account: account, chat: id)
    await composer.restoreDraft()
    guard selectedAccountID == account, selectedChatID == id, chatGeneration == generation else { return }
    actions.setContext(account: account, chat: id)
    guard let id, let account else { return }
    historyBusy = true
    do {
      let page = try await worker.messages(accountID: account, chat: id, before: nil)
      guard selectedAccountID == account, selectedChatID == id, chatGeneration == generation else {
        return
      }
      messages = page
      hasOlder = page.count == 50
      historyBusy = false
    } catch {
      if chatGeneration == generation {
        historyBusy = false
        report(error)
      }
    }
  }
  func loadOlder() async {
    guard !historyBusy, hasOlder, let account = selectedAccountID, let chat = selectedChatID,
      let cursor = messages.last?.cursor
    else { return }
    historyBusy = true
    let generation = chatGeneration
    do {
      let page = try await worker.messages(accountID: account, chat: chat, before: cursor)
      guard selectedAccountID == account, selectedChatID == chat, chatGeneration == generation
      else { return }
      let known = Set(messages.map(\.id))
      messages.append(contentsOf: page.filter { !known.contains($0.id) })
      hasOlder = page.count == 50
      historyBusy = false
    } catch {
      if chatGeneration == generation {
        historyBusy = false
        report(error)
      }
    }
  }
  func refresh() async {
    guard loaded, !refreshing, let account = selectedAccountID else { return }
    refreshing = true
    defer { refreshing = false }
    let generation = accountGeneration
    do {
      let value = try await worker.snapshot(accountID: account)
      guard selectedAccountID == account, accountGeneration == generation else { return }
      chats = WhatsAppChatListProjection.visible(value.chats)
      archiveError = value.archiveError
      var incoming: [WhatsAppNotificationEvent] = []
      notificationError = nil
      do {
        for (id, call) in try await worker.callSnapshots() { calls.observe(call, account: id) }
      } catch { notificationError = "Не удалось обновить состояние звонков WhatsApp." }
      for id in accounts.map(\.id) {
        do { incoming += try await worker.claimNotifications(accountID: id) } catch {
          notificationError = "Не удалось получить уведомления WhatsApp."
        }
      }
      if !incoming.isEmpty { notificationEvents = incoming }
      guard selectedAccountID == account, accountGeneration == generation else { return }
      if !syntheticPairing {
        await publishStatus(value.status, account: account, generation: generation)
      } else if status.expires <= Int64(Date().timeIntervalSince1970) {
        status.state = "expired"
        status.qr = ""
        qrImage = nil
      }
      if let chat = selectedChatID, !historyBusy {
        let selection = chatGeneration
        let page = try await worker.messages(accountID: account, chat: chat, before: nil)
        guard accountGeneration == generation, chatGeneration == selection, selectedChatID == chat
        else { return }
        let fresh = Set(page.map(\.id))
        // A disjoint newest page cannot prove continuity with the old
        // range. Restart paging here so its middle remains reachable.
        let overlaps = messages.contains { fresh.contains($0.id) }
        let old = overlaps ? messages.filter { !fresh.contains($0.id) } : []
        messages = (page + old).sorted {
          $0.timestamp == $1.timestamp
            ? ($0.pageToken ?? $0.id) > ($1.pageToken ?? $1.id) : $0.timestamp > $1.timestamp
        }
        if old.isEmpty { hasOlder = page.count == 50 }
      }
    } catch { if accountGeneration == generation, !Task.isCancelled { report(error) } }
  }
  func addAccount(_ name: String) async -> Bool {
    guard loaded, !busy else { return false }
    busy = true
    do {
      let account = try await worker.addAccount(name: name)
      accounts.append(account)
      busy = false
      await selectAccount(account.id)
      connect()
      return true
    } catch {
      busy = false
      report(error)
      return false
    }
  }
  func connect() {
    guard loaded, !busy, !isSynthetic, let account = selectedAccountID else { return }
    busy = true
    error = nil
    let generation = accountGeneration
    status.state = "connecting"
    let worker = worker
    operationTask = Task { [weak self] in
      do { try await worker.connect(accountID: account) } catch {
        if let self, self.accountGeneration == generation, !Task.isCancelled { self.report(error) }
      }
      guard let self, self.accountGeneration == generation else { return }
      self.busy = false
      await self.refresh()
    }
  }
  func disconnect() async {
    guard let account = selectedAccountID else { return }
    if calls.accountID == account { await calls.end() }
    operationTask?.cancel()
    accountGeneration &+= 1
    let generation = accountGeneration
    syntheticPairing = false
    status = .init()
    qrImage = nil
    busy = true
    do { try await worker.disconnect(accountID: account) } catch {
      if accountGeneration == generation { report(error) }
    }
    if accountGeneration == generation { busy = false }
  }
  #if DEBUG
    func previewPairing() async {
      guard isSynthetic, let account = selectedAccountID else { return }
      syntheticPairing = true
      status.state = "qr"
      status.qr = "MAKOSH-SYNTHETIC-NOT-A-WHATSAPP-LINK"
      status.expires = Int64(Date().timeIntervalSince1970) + 60
      await publishStatus(status, account: account, generation: accountGeneration)
    }
  #endif
  func openNotification(_ event: WhatsAppNotificationEvent) async {
    guard accounts.contains(where: { $0.id == event.accountID }) else { return }
    await selectAccount(event.accountID)
    await selectChat(event.chat)
    while selectedAccountID == event.accountID, selectedChatID == event.chat, hasOlder,
      !messages.contains(where: { $0.id == event.messageID })
    {
      await loadOlder()
      if historyBusy || error != nil { break }
    }
    guard selectedAccountID == event.accountID, selectedChatID == event.chat else { return }
    notificationActivation = UUID()
  }
  private func publishStatus(_ value: WhatsAppConnectionStatus, account: UUID, generation: UInt64)
    async
  {
    guard selectedAccountID == account, accountGeneration == generation else { return }
    let changed = status.qr != value.qr || (qrImage == nil && !value.qr.isEmpty)
    status = value
    guard value.state == "qr", value.expires > Int64(Date().timeIntervalSince1970) else {
      qrImage = nil
      return
    }
    if changed {
      let image = await Self.qrData(value.qr)
      guard selectedAccountID == account, accountGeneration == generation, status.qr == value.qr,
        status.expires > Int64(Date().timeIntervalSince1970)
      else { return }
      qrImage = image
    }
  }
  @concurrent private static func qrData(_ code: String) async -> Data? {
    guard code.utf8.count <= 8192, let filter = CIFilter(name: "CIQRCodeGenerator") else {
      return nil
    }
    filter.setValue(Data(code.utf8), forKey: "inputMessage")
    filter.setValue("L", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: space)
  }
  private func report(_ error: Error) {
    self.error = (error as? WhatsAppFailure ?? .storage).localizedDescription
  }
}

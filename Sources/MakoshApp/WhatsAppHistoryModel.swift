import Combine
import Foundation
import MakoshCore
import MakoshWhatsApp

/// Owns a single immutable source context. Search cursors advance through the
/// retained store, including pages with no matches; presentation never scans SQL.
@MainActor final class WhatsAppHistoryModel: ObservableObject {
  @Published private(set) var messages: [WhatsAppMessage] = []
  @Published private(set) var busy = false
  @Published private(set) var active = false
  @Published private(set) var hasMore = false
  @Published var error: String?
  private let worker: any WhatsAppServing
  private let accountID: UUID
  private let chat: String
  private var generation: UInt64 = 0
  private var cursor: WhatsAppCursor?
  private var query = ""
  private var filter = WhatsAppHistoryFilter.all
  init(worker: any WhatsAppServing, accountID: UUID, chat: String) {
    self.worker = worker
    self.accountID = accountID
    self.chat = chat
  }
  func clear() {
    generation &+= 1
    messages = []
    cursor = nil
    hasMore = false
    busy = false
    active = false
    error = nil
  }
  func search(query: String, filter: WhatsAppHistoryFilter) async {
    clear()
    self.query = query
    self.filter = filter
    active = true
    await loadMore()
  }
  func loadMore() async {
    guard active, !busy, cursor != nil || messages.isEmpty else { return }
    busy = true
    let revision = generation
    defer { if generation == revision { busy = false } }
    do {
      let page = try await worker.search(
        accountID: accountID, chat: chat, query: query, filter: filter, before: cursor)
      guard generation == revision, !Task.isCancelled else { return }
      let known = Set(messages.map(\.id))
      messages += page.messages.filter { !known.contains($0.id) }
      cursor = page.next
      hasMore = page.next != nil
    } catch { if generation == revision { self.error = error.localizedDescription } }
  }
}

@MainActor final class WhatsAppArchiveModel: ObservableObject {
  @Published private(set) var rows: [MessageArchiveRecord] = []
  @Published private(set) var richMessages: [UUID: WhatsAppMessage] = [:]
  @Published private(set) var busy = false
  @Published private(set) var hasMore = true
  @Published var error: String?
  let worker: any WhatsAppServing, accountID: UUID, chat: String
  private var cursor: Int64?
  init(worker: any WhatsAppServing, accountID: UUID, chat: String) {
    self.worker = worker
    self.accountID = accountID
    self.chat = chat
  }
  func more() async {
    guard !busy, hasMore else { return }
    busy = true
    defer { busy = false }
    do {
      let page = try await worker.archivePage(accountID: accountID, chat: chat, before: cursor)
      let projected = try await BackgroundWork.run {
        var values: [UUID: WhatsAppMessage] = [:]
        for row in page {
          try Task.checkCancellation()
          if let payload = row.observation.sourcePayload {
            let message = try JSONDecoder().decode(WhatsAppMessage.self, from: payload)
            guard message.id.utf8.elementsEqual(row.observation.identity.messageID.utf8), message.chat.utf8.elementsEqual(row.observation.identity.conversationID.utf8) else { throw WhatsAppFailure.invalid }
            values[row.id] = message
          }
        }
        return values
      }
      guard !Task.isCancelled else { return }
      richMessages.merge(projected) { _, value in value }
      rows += page
      cursor = page.last?.sequence
      hasMore = page.count == 100
    } catch { self.error = error.localizedDescription }
  }
  func export() async -> WhatsAppFileLease? {
    guard !busy else { return nil }
    busy = true
    defer { busy = false }
    do { return try await worker.exportChat(accountID: accountID, chat: chat) } catch {
      self.error = error.localizedDescription
      return nil
    }
  }
}

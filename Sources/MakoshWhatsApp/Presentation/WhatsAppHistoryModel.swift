import Combine
import Foundation
import MakoshCore

/// Owns a single immutable source context. Search cursors advance through the
/// retained store, including pages with no matches; presentation never scans SQL.
@MainActor package final class WhatsAppHistoryModel: ObservableObject {
  @Published package private(set) var messages: [WhatsAppMessage] = []
  @Published package private(set) var busy = false
  @Published package private(set) var active = false
  @Published package private(set) var hasMore = false
  @Published package var error: String?
  private let worker: any WhatsAppServing
  private let accountID: UUID
  private let chat: String
  private var generation: UInt64 = 0
  private var cursor: WhatsAppCursor?
  private var query = ""
  private var filter = WhatsAppHistoryFilter.all
  package init(worker: any WhatsAppServing, accountID: UUID, chat: String) {
    self.worker = worker
    self.accountID = accountID
    self.chat = chat
  }
  package func clear() {
    generation &+= 1
    messages = []
    cursor = nil
    hasMore = false
    busy = false
    active = false
    error = nil
  }
  package func search(query: String, filter: WhatsAppHistoryFilter) async {
    clear()
    self.query = query
    self.filter = filter
    active = true
    await loadMore()
  }
  package func loadMore() async {
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

@MainActor package final class WhatsAppArchiveModel: ObservableObject {
  @Published package private(set) var rows: [MessageArchiveRecord] = []
  @Published package private(set) var richMessages: [UUID: WhatsAppMessage] = [:]
  @Published package private(set) var busy = false
  @Published package private(set) var hasMore = true
  @Published package var error: String?
  package let worker: any WhatsAppServing, accountID: UUID, chat: String
  private var cursor: Int64?
  package init(worker: any WhatsAppServing, accountID: UUID, chat: String) {
    self.worker = worker
    self.accountID = accountID
    self.chat = chat
  }
  package func more() async {
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
            guard message.id.utf8.elementsEqual(row.observation.identity.messageID.utf8),
              message.chat.utf8.elementsEqual(row.observation.identity.conversationID.utf8)
            else { throw WhatsAppFailure.invalid }
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
  package func export() async -> WhatsAppFileLease? {
    guard !busy else { return nil }
    busy = true
    defer { busy = false }
    do { return try await worker.exportChat(accountID: accountID, chat: chat) } catch {
      self.error = error.localizedDescription
      return nil
    }
  }
}

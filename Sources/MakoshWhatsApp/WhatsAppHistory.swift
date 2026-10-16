import Darwin
import Foundation
import MakoshCore

public enum WhatsAppHistoryFilter: String, CaseIterable, Codable, Sendable {
  case all, starred, pinned, media, documents, links, currentStatus
}
public struct WhatsAppSearchPage: Sendable {
  public let messages: [WhatsAppMessage]
  public let next: WhatsAppCursor?
  public init(messages: [WhatsAppMessage], next: WhatsAppCursor?) {
    self.messages = messages
    self.next = next
  }
}
extension WhatsAppRepository {
  public func search(
    accountID: UUID, chat: String, query: String, filter: WhatsAppHistoryFilter,
    before: WhatsAppCursor?, limit: Int = 50
  ) throws -> WhatsAppSearchPage {
    guard (1...100).contains(limit), query.utf8.count <= 4096 else { throw WhatsAppFailure.invalid }
    var cursor = before
    var found: [WhatsAppMessage] = []
    var scanned = 0
    while scanned < 1000 {
      try Task.checkCancellation()
      let page = try messages(accountID: accountID, chat: chat, before: cursor, limit: 100)
      for message in page {
        cursor = message.cursor
        scanned += 1
        let match: Bool
        switch filter {
        case .all: match = true
        case .starred: match = message.details?.starred == true
        case .pinned: match = message.details?.pinned == true
        case .media: match = ["image", "video", "audio", "sticker"].contains(message.kind)
        case .documents: match = message.kind == "document"
        case .links: match = message.text.contains("https://") || message.text.contains("http://")
        case .currentStatus:
          match = message.timestamp >= Int64(Date().timeIntervalSince1970) - 86400
        }
        if match
          && (query.isEmpty || message.text.localizedCaseInsensitiveContains(query)
            || message.details?.name?.localizedCaseInsensitiveContains(query) == true
            || message.details?.pollName?.localizedCaseInsensitiveContains(query) == true)
        {
          found.append(message)
        }
        if found.count == limit { return .init(messages: found, next: cursor) }
      }
      if page.count < 100 { return .init(messages: found, next: nil) }
    }
    return .init(messages: found, next: cursor)
  }
  public func archivePage(accountID: UUID, chat: String, before: Int64?, limit: Int = 100) throws
    -> [MessageArchiveRecord]
  {
    try retained().records(
      service: "whatsapp", accountID: accountID.uuidString, conversationID: chat, before: before,
      limit: limit)
  }
  func exportChat(accountID: UUID, chat: String, to file: URL) throws {
    let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw WhatsAppFailure.storage }
    defer { Darwin.close(fd) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var before: Int64?
    repeat {
      let rows = try archivePage(accountID: accountID, chat: chat, before: before)
      for row in rows {
        try Task.checkCancellation()
        var line = try encoder.encode(row.observation)
        line.append(10)
        try line.withUnsafeBytes { bytes in
          var offset = 0
          while offset < bytes.count {
            let count = Darwin.write(
              fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw WhatsAppFailure.storage }
            offset += count
          }
        }
      }
      before = rows.count == 100 ? rows.last?.sequence : nil
    } while before != nil
    guard fsync(fd) == 0 else { throw WhatsAppFailure.storage }
  }
}
extension WhatsAppServing {
  public func search(
    accountID: UUID, chat: String, query: String, filter: WhatsAppHistoryFilter,
    before: WhatsAppCursor?
  ) async throws -> WhatsAppSearchPage { throw WhatsAppFailure.unavailable }
  public func archivePage(accountID: UUID, chat: String, before: Int64?) async throws
    -> [MessageArchiveRecord]
  { throw WhatsAppFailure.unavailable }
  public func exportChat(accountID: UUID, chat: String) async throws -> WhatsAppFileLease {
    throw WhatsAppFailure.unavailable
  }
}
extension WhatsAppWorker {
  public func search(
    accountID: UUID, chat: String, query: String, filter: WhatsAppHistoryFilter,
    before: WhatsAppCursor?
  ) async throws -> WhatsAppSearchPage {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.search(
      accountID: accountID, chat: chat, query: query, filter: filter, before: before)
  }
  public func archivePage(accountID: UUID, chat: String, before: Int64?) async throws
    -> [MessageArchiveRecord]
  {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.archivePage(accountID: accountID, chat: chat, before: before)
  }
  public func exportChat(accountID: UUID, chat: String) async throws -> WhatsAppFileLease {
    guard let repository, let files else { throw WhatsAppFailure.storage }
    let lease = try await files.makeLease(name: "WhatsApp-archive.jsonl")
    do {
      try await repository.exportChat(accountID: accountID, chat: chat, to: lease.url)
      return lease
    } catch {
      lease.remove()
      throw error
    }
  }
}

import Foundation

extension WhatsAppServing {
  public func outgoingPage(accountID: UUID, before: WhatsAppOutgoingCursor?) async throws -> WhatsAppOutgoingPage {
    guard before == nil else { return .init(values: [], next: nil) }
    return try await .init(values: outgoing(accountID: accountID), next: nil)
  }
  public func info(accountID: UUID, chat: String, operation: WhatsAppAction.Operation) async throws
    -> WhatsAppPeerInfo
  { throw WhatsAppFailure.unavailable }
  public func savedNotificationRule(accountID: UUID?, chat: String?) async throws
    -> WhatsAppNotificationRule
  { throw WhatsAppFailure.unavailable }
  public func setNotificationRule(_ rule: WhatsAppNotificationRule, accountID: UUID?, chat: String?)
    async throws
  { throw WhatsAppFailure.unavailable }
  public func notificationRule(accountID: UUID, chat: String) async throws
    -> WhatsAppNotificationRule
  { throw WhatsAppFailure.unavailable }
  public func claimNotifications(accountID: UUID) async throws -> [WhatsAppNotificationEvent] {
    throw WhatsAppFailure.unavailable
  }
  public func notificationIsCurrent(_ event: WhatsAppNotificationEvent) async throws -> Bool {
    false
  }
}
extension WhatsAppWorker {
  public func info(accountID: UUID, chat: String, operation: WhatsAppAction.Operation) async throws
    -> WhatsAppPeerInfo
  {
    #if DEBUG
    if let value=try await qaInfo(accountID:accountID,chat:chat,operation:operation) {return value}
    #endif
    guard [.profile, .userInfo, .privacy, .groupInfo, .groupLink, .avatar].contains(operation),
      let session = sessions[accountID], !synthetic
    else { throw WhatsAppFailure.closed }
    let generation = revisions[accountID]
    let result = try await session.perform(chat: chat, action: .init(operation))
    guard revisions[accountID] == generation else { throw CancellationError() }
    guard let value = result.info else { throw WhatsAppFailure.protocolFailure }
    return value
  }
  public func savedNotificationRule(accountID: UUID?, chat: String?) async throws
    -> WhatsAppNotificationRule
  {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.savedNotificationRule(accountID: accountID, chat: chat)
  }
  public func setNotificationRule(_ rule: WhatsAppNotificationRule, accountID: UUID?, chat: String?)
    async throws
  {
    guard let repository else { throw WhatsAppFailure.storage }
    try await repository.setNotificationRule(rule, accountID: accountID, chat: chat)
  }
  public func notificationRule(accountID: UUID, chat: String) async throws
    -> WhatsAppNotificationRule
  {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.notificationRule(accountID: accountID, chat: chat)
  }
  public func claimNotifications(accountID: UUID) async throws -> [WhatsAppNotificationEvent] {
    guard let repository else { return [] }
    let generation = revisions[accountID]
    if !synthetic {
      guard let session = sessions[accountID], try await session.status().linked else { return [] }
    }
    let values = try await repository.claimNotifications(accountID: accountID)
    guard revisions[accountID] == generation else { return [] }
    return values
  }
  public func notificationIsCurrent(_ event: WhatsAppNotificationEvent) async throws -> Bool {
    guard let repository else { return false }
    let generation = revisions[event.accountID]
    if !synthetic {
      guard let session = sessions[event.accountID], try await session.status().linked else {
        return false
      }
    }
    let valid = try await repository.notificationIsCurrent(event)
    guard revisions[event.accountID] == generation else { return false }
    if !synthetic {
      guard let session = sessions[event.accountID], try await session.status().linked,
        revisions[event.accountID] == generation
      else { return false }
    }
    return valid
  }
}

extension WhatsAppServing {
  public func openChat(accountID: UUID, chat: String) async throws {
    throw WhatsAppFailure.unavailable
  }
}
extension WhatsAppWorker {
  public func openChat(accountID: UUID, chat: String) async throws {
    guard let repository, try await repository.accounts().contains(where: { $0.id == accountID }),
      chat.utf8.count <= 1024, !chat.contains(where: { $0.isWhitespace }),
      ["@lid", "@s.whatsapp.net", "@g.us"].contains(where: chat.hasSuffix)
    else { throw WhatsAppFailure.invalid }
    let known = try await repository.chats(accountID: accountID)
    if !known.contains(where: { $0.id.utf8.elementsEqual(chat.utf8) }) {
      try await repository.saveChats(
        [
          .init(
            id: chat, name: chat, timestamp: Int64(Date().timeIntervalSince1970),
            group: chat.hasSuffix("@g.us"))
        ], accountID: accountID)
    }
  }
}

import Foundation
import MakoshCore

public struct WhatsAppWorkspaceSnapshot: Sendable {
  public let accountID: UUID
  public let status: WhatsAppConnectionStatus
  public let chats: [WhatsAppChat]
  public let archiveError: String?
  public init(
    accountID: UUID, status: WhatsAppConnectionStatus, chats: [WhatsAppChat],
    archiveError: String? = nil
  ) {
    self.accountID = accountID
    self.status = status
    self.chats = chats
    self.archiveError = archiveError
  }
}
public protocol WhatsAppServing: Sendable {
  func load(configuration: ContactWorkspaceConfiguration) async throws -> [WhatsAppAccount]
  func addAccount(name: String) async throws -> WhatsAppAccount
  func snapshot(accountID: UUID) async throws -> WhatsAppWorkspaceSnapshot
  func openChat(accountID: UUID, chat: String) async throws
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) async throws
    -> [WhatsAppMessage]
  func connect(accountID: UUID) async throws
  func disconnect(accountID: UUID) async throws
  func send(accountID: UUID, chat: String, content: WhatsAppOutgoingContent) async throws
    -> WhatsAppOutgoing
  func sendBatch(accountID: UUID, chat: String, content: WhatsAppOutgoingContent) async throws -> WhatsAppBatchSnapshot
  func continueBatch(accountID: UUID, id: UUID) async throws -> WhatsAppBatchSnapshot
  func batch(accountID: UUID, id: UUID) async throws -> WhatsAppBatchSnapshot
  func perform(accountID: UUID, chat: String, action: WhatsAppAction) async throws
    -> WhatsAppOutgoing
  func resumeOutgoing(accountID: UUID, id: UUID) async throws -> WhatsAppOutgoing
  func copyOutgoing(accountID: UUID, id: UUID) async throws -> WhatsAppOutgoing
  func outgoingPage(accountID: UUID, before: WhatsAppOutgoingCursor?) async throws -> WhatsAppOutgoingPage
  func outgoing(accountID: UUID) async throws -> [WhatsAppOutgoing]
  func resolveOutgoing(accountID: UUID, id: UUID, sent: Bool) async throws
  func prepareVoice(accountID: UUID, chat: String, samples: [Int16]) async throws
    -> WhatsAppPreparedFile
  func capturePhoto(accountID: UUID,chat: String,file: URL) async throws -> WhatsAppPhotoDraft
  func savePhotoRecipe(id: UUID,accountID: UUID,chat: String,expectedRevision: UInt64,recipe: WhatsAppPhotoRecipe) async throws -> WhatsAppPhotoDraft
  func photoPreview(id: UUID,accountID: UUID,chat: String,expectedRevision: UInt64) async throws -> WhatsAppPhotoPreview
  func renderPhoto(id: UUID,accountID: UUID,chat: String,expectedRevision: UInt64,mode: WhatsAppPhotoMode) async throws -> WhatsAppPreparedFile
  func photoDrafts(accountID: UUID,chat: String) async throws -> [WhatsAppPhotoDraft]
  func saveComposeDraft(_ draft: WhatsAppComposeDraft,expectedRevision: UInt64?) async throws -> WhatsAppComposeDraft
  func composeDraft(accountID: UUID,chat: String) async throws -> WhatsAppComposeDraft?
  func preparedFile(accountID: UUID,chat: String,id: UUID) async throws -> WhatsAppPreparedFile
  func prepareFile(accountID: UUID, chat: String, file: URL, kind: String, mime: String)
    async throws -> WhatsAppPreparedFile
  func savingFiles(accountID: UUID, chat: String) async throws -> Bool
  func setSavingFiles(accountID: UUID, chat: String, enabled: Bool) async throws
  func downloadVersion(
    accountID: UUID, chat: String, id: String, resource: String, kind: String, name: String
  ) async throws -> WhatsAppFileLease
  func download(accountID: UUID, chat: String, id: String) async throws -> WhatsAppFileLease
  func info(accountID: UUID, chat: String, operation: WhatsAppAction.Operation) async throws
    -> WhatsAppPeerInfo
  func avatar(accountID: UUID, jid: String, refresh: Bool) async throws -> WhatsAppAvatarImage?
  func savedNotificationRule(accountID: UUID?, chat: String?) async throws
    -> WhatsAppNotificationRule
  func setNotificationRule(_ rule: WhatsAppNotificationRule, accountID: UUID?, chat: String?)
    async throws
  func notificationRule(accountID: UUID, chat: String) async throws -> WhatsAppNotificationRule
  func claimNotifications(accountID: UUID) async throws -> [WhatsAppNotificationEvent]
  func notificationIsCurrent(_ event: WhatsAppNotificationEvent) async throws -> Bool
  func search(
    accountID: UUID, chat: String, query: String, filter: WhatsAppHistoryFilter,
    before: WhatsAppCursor?
  ) async throws -> WhatsAppSearchPage
  func archivePage(accountID: UUID, chat: String, before: Int64?) async throws
    -> [MessageArchiveRecord]
  func exportChat(accountID: UUID, chat: String) async throws -> WhatsAppFileLease
  func startGroupCall(accountID: UUID,groupJID: String,participants: [String],video: Bool) async throws -> WhatsAppOutgoing
  func startGroupCall(accountID: UUID,groupJID: String,participants: [String],video: Bool,callContext:UUID?) async throws -> WhatsAppOutgoing
  func inviteCallParticipant(accountID: UUID,callID: String,epoch: UInt64,jid: String,ringOnly: Bool) async throws -> WhatsAppOutgoing
  func cancelAcceptedCall(accountID:UUID,outgoingID:UUID) async throws
  func callSnapshots() async throws -> [UUID: WhatsAppCallSnapshot]
  func callMedia(accountID: UUID, request: WhatsAppCallExchange) async throws -> WhatsAppCallOutput
  func activateNotification(token: String) async throws -> WhatsAppNotificationEvent?
  func shutdown() async
}
public actor WhatsAppWorker: WhatsAppServing {
  let synthetic: Bool
  var qaRoot:URL?
  var repository: WhatsAppRepository?
  var sessions: [UUID: any WhatsAppTransport] = [:]
  var revisions: [UUID: UInt64] = [:]
  var photos: WhatsAppPhotoPreparation?
  var files: WhatsAppFiles?
  var avatars: WhatsAppAvatars?
  var avatarEpochs: [UUID: UInt64] = [:]
  var avatarRevisions: [UUID: [String: UInt64]] = [:]
  private var materialized: [UUID: UInt64] = [:]
  private var failures: [UUID: WhatsAppConnectionStatus] = [:]
  private let factory: (@Sendable (UUID) async throws -> any WhatsAppTransport)?
  private let vaultKeys: @Sendable (UUID, Bool) throws -> Data
  public init(synthetic: Bool = false) {
    self.synthetic = synthetic
    factory = nil
    if synthetic {
      vaultKeys = { _, _ in Data(repeating: 0x79, count: 32) }
    } else {
      vaultKeys = { id, create in
        try MessageArchiveKeychain.open(vaultID: id, allowCreation: create)
      }
    }
  }
  init(
    factory: @escaping @Sendable (UUID) async throws -> any WhatsAppTransport,
    keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data
  ) {
    synthetic = false
    self.factory = factory
    vaultKeys = keyProvider
  }
  public func load(configuration: ContactWorkspaceConfiguration) async throws -> [WhatsAppAccount] {
    if synthetic {
      guard configuration.schema.hasPrefix("qa_whatsapp_"),
        (configuration.archiveSchema ?? configuration.schema).hasPrefix("qa_whatsapp_")
      else { throw WhatsAppFailure.invalid }
    }
    if repository == nil {
      repository = WhatsAppRepository(configuration: configuration, keyProvider: vaultKeys)
    }
    guard let repository else { throw WhatsAppFailure.storage }
    if files == nil {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("Makosh")
      let args = CommandLine.arguments
      let storage: URL
      if let i = args.firstIndex(of: "--storage-config"), args.indices.contains(i + 1),
        !args[i + 1].hasPrefix("--")
      {
        storage = URL(fileURLWithPath: args[i + 1])
      } else {
        storage = support.appendingPathComponent("s3.json")
      }
      files = WhatsAppFiles(
        configuration: configuration, storageFile: storage,
        spool: support.appendingPathComponent(
          synthetic ? "WhatsAppQA/\(configuration.schema)/Files" : "FileArchiveQueue"),
        repository: repository, keyProvider: vaultKeys)
    }
    if synthetic, try await repository.accounts().isEmpty { try await seed(repository) }
    if avatars == nil, !synthetic {
      let root = try FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Makosh/WhatsApp/Avatars")
      avatars = WhatsAppAvatars(root: root, http: WhatsAppAvatarHTTP(),
        keyProvider: { account in try await repository.avatarCacheKey(accountID: account) },
        descriptor: { [weak self] scope in
          guard let self else { throw WhatsAppFailure.closed }
          return try await self.info(accountID: scope.accountID, chat: scope.jid, operation: .avatar).avatar
        })
    }
    return try await repository.accounts()
  }
  public func addAccount(name: String) async throws -> WhatsAppAccount {
    guard let repository, !synthetic else { throw WhatsAppFailure.invalid }
    let account = WhatsAppAccount(name: name)
    try await repository.saveAccount(account)
    return account
  }
  public func connect(accountID: UUID) async throws {
    guard let repository, !synthetic,
      try await repository.accounts().contains(where: { $0.id == accountID })
    else { throw WhatsAppFailure.invalid }
    archiveTasks.removeValue(forKey: accountID)?.cancel()
    archiveTaskTokens.removeValue(forKey: accountID)
    revisions[accountID, default: 0] &+= 1
    let revision = revisions[accountID]
    materialized[accountID] = nil
    failures[accountID] = nil
    if let old = sessions.removeValue(forKey: accountID) { try await old.close() }
    let session: any WhatsAppTransport
    if let factory {
      session = try await factory(accountID)
    } else {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let directory = support.appendingPathComponent(
        "Makosh/WhatsApp/accounts/" + accountID.uuidString.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var key = try WhatsAppKeychain.open(
        account: accountID,
        allowCreation: !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("session.db").path))
      defer { key.resetBytes(in: 0..<key.count) }
      let native = WhatsAppNativeSession(
        executable: Bundle.main.bundleURL.appendingPathComponent(
          "Contents/Helpers/MakoshWhatsAppWorker"))
      try await native.open(directory: directory, key: key)
      session = native
    }
    guard revisions[accountID] == revision else {
      try await session.close()
      throw CancellationError()
    }
    avatarEpochs[accountID] = nil; avatarRevisions[accountID] = nil
    await avatars?.invalidateAccount(accountID)
    guard revisions[accountID] == revision else { try await session.close(); throw CancellationError() }
    sessions[accountID] = session
    do {
      try await session.connect()
      try Task.checkCancellation()
    } catch {
      if revisions[accountID] == revision { sessions.removeValue(forKey: accountID) }
      try? await session.close()
      throw error
    }
    guard revisions[accountID] == revision else {
      try await session.close()
      throw CancellationError()
    }
  }
  var acceptedCalls:[UUID:(id:UUID,generation:UInt64)]=[:]
  var callRevisions: [UUID: UInt64] = [:]
  var archiveTasks: [UUID: Task<Void, Never>] = [:]
  var archiveTaskTokens: [UUID: UUID] = [:]
  var archiveFailures: [UUID: String] = [:]
  public func disconnect(accountID: UUID) async throws {
    archiveTasks.removeValue(forKey: accountID)?.cancel()
    archiveTaskTokens.removeValue(forKey: accountID)
    revisions[accountID, default: 0] &+= 1
    let session = sessions.removeValue(forKey: accountID)
    avatarEpochs[accountID] = nil; avatarRevisions[accountID] = nil
    materialized[accountID] = nil
    failures[accountID] = nil
    await avatars?.invalidateAccount(accountID)
    if let session { try await session.close() }
  }
  public func snapshot(accountID: UUID) async throws -> WhatsAppWorkspaceSnapshot {
    guard let repository else { throw WhatsAppFailure.storage }
    // All connected accounts drain their durable journals, including those
    // not currently displayed. A window's selection never becomes ownership.
    for (id, session) in sessions {
      let revision = revisions[id]
      do {
        try await transfer(id, session: session, repository: repository)
        if revisions[id] == revision { failures[id] = nil }
      } catch {
        if revisions[id] == revision {
          var failed = WhatsAppConnectionStatus()
          failed.state = "failed"
          failed.error = "service"
          failures[id] = failed
        }
      }
    }
    let status: WhatsAppConnectionStatus
    if let failed = failures[accountID] {
      status = failed
    } else {
      status = try await sessions[accountID]?.status() ?? .init()
    }
    return try await .init(
      accountID: accountID, status: status, chats: repository.chats(accountID: accountID),
      archiveError: archiveFailures[accountID])
  }
  private func transfer(
    _ accountID: UUID, session: any WhatsAppTransport, repository: WhatsAppRepository
  ) async throws {
    let revision = revisions[accountID]
    for _ in 0..<4 {
      let entries = try await session.journal()
      if entries.isEmpty { break }
      try await repository.ingest(entries, accountID: accountID)
      for entry in entries
      where ["image", "video", "audio", "sticker", "document"].contains(entry.message.kind)
        && entry.message.details?.resourceID != nil
      {
        if entry.message.outgoing, let resource = entry.message.details?.resourceID,
          try await repository.bindOutgoingResource(
            accountID: accountID, chat: entry.message.chat, stanza: entry.message.stanza,
            resource: resource)
        {
          continue
        }
        if let files, try await files.saving(accountID: accountID, chat: entry.message.chat) {
          _ = try await repository.reserveIncomingFile(accountID: accountID, message: entry.message)
        }
      }
      guard revisions[accountID] == revision else { return }
      if let last = entries.last { try await session.acknowledge(last.sequence) }
    }
    kickIncomingFiles(accountID)
    let status = try await session.status()
    guard revisions[accountID] == revision else { return }
    await updateAvatars(status, accountID: accountID)
    guard revisions[accountID] == revision else { return }
    if materialized[accountID] != status.revision {
      var before: WhatsAppCursor?
      repeat {
        let chats = try await session.chats(before: before)
        guard revisions[accountID] == revision else { return }
        try await repository.saveChats(chats, accountID: accountID)
        before =
          chats.count == 100 ? chats.last.map { .init(timestamp: $0.timestamp, id: $0.id) } : nil
      } while before != nil
      materialized[accountID] = status.revision
    }
  }
  public func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) async throws
    -> [WhatsAppMessage]
  {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.messages(accountID: accountID, chat: chat, before: before)
  }
  public func shutdown() async {
    for task in archiveTasks.values { task.cancel() }
    archiveTasks.removeAll()
    archiveTaskTokens.removeAll()
    let active = sessions
    sessions.removeAll()
    failures.removeAll()
    for id in active.keys { revisions[id, default: 0] &+= 1 }
    await avatars?.close(); avatars = nil
    avatarEpochs.removeAll(); avatarRevisions.removeAll()
    for session in active.values { try? await session.close() }
  }
  private func seed(_ repository: WhatsAppRepository) async throws {
    let first = WhatsAppAccount(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000101")!, name: "Личный · тест")
    let second = WhatsAppAccount(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000102")!, name: "Рабочий · тест")
    for account in [first, second] { try await repository.saveAccount(account) }
    let chats = [
      WhatsAppChat(
        id: "test-alex@lid", name: "Алексей Тестовый", timestamp: 1_792_044_600, unread: 3,
        pinned: true),
      WhatsAppChat(
        id: "test-team@g.us", name: "Команда Макоша", timestamp: 1_792_044_000, group: true),
      WhatsAppChat(
        id: "test-archive@lid", name: "Архивный чат", timestamp: 1_792_040_000, archived: true),
    ]
    try await repository.saveChats(chats, accountID: first.id)
    var entries: [WhatsAppJournalEntry] = []
    for n in 1...64 {
      let message = WhatsAppMessage(
        chat: chats[0].id, id: "test-\(n)", stanza: "test-\(n)",
        sender: n % 2 == 0 ? "" : "test-alex@lid", timestamp: 1_792_040_000 + Int64(n * 60),
        outgoing: n % 2 == 0,
        text: n == 64
          ? "История доступна офлайн. Сеть и реальные аккаунты не используются."
          : "Тестовое сообщение · \(n)", kind: "text", edited: false, deleted: false)
      entries.append(
        .init(sequence: Int64(n), message: message, history: true, observed: 1_792_044_600))
    }
    for chunk in stride(from: 0, to: entries.count, by: 100) {
      try await repository.ingest(
        Array(entries[chunk..<min(chunk + 100, entries.count)]), accountID: first.id)
    }
    var deleted = entries[2]
    deleted.sequence = 65
    deleted.history = false
    deleted.message.deleted = true
    try await repository.ingest([deleted], accountID: first.id)
  }
}

import Foundation

extension WhatsAppServing {
  public func sendBatch(accountID: UUID, chat: String, content: WhatsAppOutgoingContent)
    async throws -> WhatsAppBatchSnapshot
  { throw WhatsAppFailure.unavailable }
  public func continueBatch(accountID: UUID, id: UUID) async throws -> WhatsAppBatchSnapshot {
    throw WhatsAppFailure.unavailable
  }
  public func batch(accountID: UUID, id: UUID) async throws -> WhatsAppBatchSnapshot {
    throw WhatsAppFailure.unavailable
  }
}

extension WhatsAppWorker {
  public func batch(accountID: UUID, id: UUID) async throws -> WhatsAppBatchSnapshot {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.batch(id: id, accountID: accountID)
  }
  public func sendBatch(accountID: UUID, chat: String, content: WhatsAppOutgoingContent)
    async throws -> WhatsAppBatchSnapshot
  {
    guard let repository, let files, (1...10).contains(content.files.count), content.action == nil,
      Set(content.files).count == content.files.count
    else { throw WhatsAppFailure.invalid }
    let generation = revisions[accountID]
    if !synthetic {
      guard let session = sessions[accountID], try await session.status().linked,
        revisions[accountID] == generation
      else { throw WhatsAppFailure.closed }
    }
    try await repository.validateOutgoing(chat: chat, content: content)
    guard revisions[accountID] == generation else { throw WhatsAppFailure.closed }
    for id in content.files {
      _ = try await files.prepared(id: id, accountID: accountID, chat: chat)
      guard revisions[accountID] == generation else { throw WhatsAppFailure.closed }
    }
    let admitted = try await repository.prepareOutgoingBatch(
      accountID: accountID, chat: chat, content: content)
    if synthetic { return admitted }
    return try await dispatchBatch(
      accountID: accountID, id: admitted.batch.id, generation: generation, continuing: false)
  }
  public func continueBatch(accountID: UUID, id: UUID) async throws -> WhatsAppBatchSnapshot {
    if synthetic { return try await batch(accountID: accountID, id: id) }
    let generation = revisions[accountID]
    guard let session = sessions[accountID], try await session.status().linked,
      revisions[accountID] == generation
    else { throw WhatsAppFailure.closed }
    return try await dispatchBatch(
      accountID: accountID, id: id, generation: generation, continuing: true)
  }
  private func dispatchBatch(accountID: UUID, id: UUID, generation: UInt64?, continuing: Bool)
    async throws -> WhatsAppBatchSnapshot
  {
    guard let repository else { throw WhatsAppFailure.storage }
    var initial = try await repository.batch(id: id, accountID: accountID)
    guard revisions[accountID] == generation else {
      initial.issue = .init(childID: nil, reason: .connection)
      return initial
    }
    if let unknown = initial.children.first(where: {
      $0.state == .unknown || $0.state == .dispatching
    }) {
      initial.issue = .init(childID: unknown.id, reason: .uncertain)
      return initial
    }
    if initial.children.allSatisfy({ $0.state != .prepared }) { return initial }
    let lease: WhatsAppBatchLease
    do {
      lease = try await repository.claimBatch(id: id, accountID: accountID, continuing: continuing)
    } catch let error as WhatsAppFailure where error == .owned {
      initial.issue = .init(childID: nil, reason: .owned)
      return initial
    }
    do {
      var issue: WhatsAppBatchIssue?
      while true {
        let snapshot = try await repository.batch(id: id, accountID: accountID)
        guard revisions[accountID] == generation else {
          issue = .init(childID: nil, reason: .connection)
          break
        }
        if Task.isCancelled {
          issue = .init(childID: nil, reason: .cancelled)
          break
        }
        if let failed = snapshot.children.first(where: {
          $0.state != .prepared && !lease.permitsPrefix($0)
        }) {
          issue = .init(childID: failed.id, reason: reason(for: failed.state))
          break
        }
        guard let child = snapshot.children.first(where: { $0.state == .prepared }) else { break }
        do {
          let result = try await sendContent(
            accountID: accountID, chat: snapshot.batch.chat,
            content: child.content, prepared: child, batchLease: lease, sourceGeneration: generation
          )
          if result.state != .sent {
            issue = .init(childID: child.id, reason: reason(for: result.state))
            break
          }
        } catch {
          let current = try await repository.batch(id: id, accountID: accountID)
          let state = current.children.first(where: { $0.id == child.id })?.state ?? .unknown
          let reason: WhatsAppBatchIssue.Reason =
            state == .prepared
            ? ((error as? WhatsAppFailure) == .closed ? .connection : .preparation)
            : reason(for: state)
          issue = .init(childID: child.id, reason: reason)
          break
        }
      }
      var result = try await repository.batch(id: id, accountID: accountID)
      result.issue = issue
      try await repository.releaseBatch(lease)
      return result
    } catch {
      try? await repository.releaseBatch(lease)
      throw error
    }
  }
  private func reason(for state: WhatsAppOutgoing.State) -> WhatsAppBatchIssue.Reason {
    switch state {
    case .unknown, .dispatching: .uncertain
    case .notSent: .notSent
    case .rejected: .rejected
    default: .preparation
    }
  }
}

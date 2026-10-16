import Foundation

public struct WhatsAppIncomingFileJob: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let accountID: UUID
  public let message: WhatsAppMessage
  public var state: String = "queued"
  public var attempts: Int = 0
  public var nextTry: Date = .distantPast
}
extension WhatsAppRepository {
  func reserveIncomingFile(accountID: UUID, message: WhatsAppMessage) throws
    -> WhatsAppIncomingFileJob
  {
    guard let resource = message.details?.resourceID else { throw WhatsAppFailure.invalid }
    let db = try db()
    let token = db.token([
      accountID.uuidString, "incoming-file", message.chat, message.id, resource,
    ])
    return try db.transaction {
      if let row = try db.query(
        "SELECT ciphertext FROM \(db.fileJobsTable) WHERE token=$1 FOR UPDATE", [token]
      ).first {
        return try db.decode(row[0], token: token)
      }
      let job = WhatsAppIncomingFileJob(id: UUID(), accountID: accountID, message: message)
      _ = try db.query(
        "INSERT INTO \(db.fileJobsTable)(token,account,ciphertext,state,next_try) VALUES($1,$2,$3,'queued',0)",
        [token, accountID.uuidString, try db.seal(job, token: token)])
      return job
    }
  }
  func incomingFileJobs(accountID: UUID) throws -> [WhatsAppIncomingFileJob] {
    let db = try db()
    var jobs: [WhatsAppIncomingFileJob] = []
    // Legacy rows are reconciled in bounded pages; opaque state/due indexes
    // contain no message/file content. Completed rows never block the queue.
    for _ in 0..<10 {
      let rows = try db.query(
        "SELECT token,ciphertext FROM \(db.fileJobsTable) WHERE account=$1 AND (state IS NULL OR (state='queued' AND next_try<=$2::bigint)) ORDER BY token LIMIT 10",
        [accountID.uuidString, String(Int64(Date().timeIntervalSince1970))])
      if rows.isEmpty { break }
      for row in rows {
        let job: WhatsAppIncomingFileJob = try db.decode(row[1], token: row[0])
        try saveIncomingFileJob(job)
        if job.state == "queued", job.nextTry <= Date() { jobs.append(job) }
      }
      if !jobs.isEmpty { break }
    }
    return Array(jobs.prefix(10))
  }
  func saveIncomingFileJob(_ job: WhatsAppIncomingFileJob) throws {
    guard let resource = job.message.details?.resourceID else { throw WhatsAppFailure.invalid }
    let db = try db()
    let token = db.token([
      job.accountID.uuidString, "incoming-file", job.message.chat, job.message.id, resource,
    ])
    try db.transaction {
      guard
        let row = try db.query(
          "SELECT ciphertext FROM \(db.fileJobsTable) WHERE token=$1 FOR UPDATE", [token]
        ).first
      else { throw WhatsAppFailure.invalid }
      let old: WhatsAppIncomingFileJob = try db.decode(row[0], token: token)
      guard old.id == job.id, old.accountID == job.accountID, old.message == job.message else {
        throw WhatsAppFailure.invalid
      }
      _ = try db.query(
        "UPDATE \(db.fileJobsTable) SET ciphertext=$2,state=$3,next_try=$4::bigint WHERE token=$1",
        [
          token, try db.seal(job, token: token), job.state,
          String(max(0, Int64(job.nextTry.timeIntervalSince1970))),
        ])
    }
  }
}
extension WhatsAppWorker {
  func kickIncomingFiles(_ accountID: UUID) {
    guard archiveTasks[accountID] == nil, sessions[accountID] != nil, !synthetic else { return }
    let generation = revisions[accountID]
    let token = UUID()
    archiveTaskTokens[accountID] = token
    archiveTasks[accountID] = Task { [weak self] in
      await self?.archivePendingFiles(accountID, generation: generation, token: token)
    }
  }
  private func archivePendingFiles(_ accountID: UUID, generation: UInt64?, token: UUID) async {
    defer {
      if archiveTaskTokens[accountID] == token {
        archiveTaskTokens.removeValue(forKey: accountID)
        archiveTasks.removeValue(forKey: accountID)
      }
    }
    guard let repository, let files else { return }
    do {
      archiveFailures[accountID] = nil
      for var job in try await repository.incomingFileJobs(accountID: accountID) {
        guard !Task.isCancelled, revisions[accountID] == generation else { return }
        do {
          if try await files.saving(accountID: accountID, chat: job.message.chat) {
            guard !Task.isCancelled, revisions[accountID] == generation else { return }
            let lease = try await downloadMessage(accountID: accountID, message: job.message, expectedGeneration: generation)
            lease.remove()
            job.state =
              try await files.archived(accountID: accountID, message: job.message).isEmpty
              ? "refused" : "complete"
          } else {
            job.state = "refused"
          }
        } catch {
          guard !Task.isCancelled, revisions[accountID] == generation else { return }
          archiveFailures[accountID] =
            "Не удалось сохранить вложение WhatsApp. Повтор запланирован."
          job.attempts += 1
          job.nextTry = Date().addingTimeInterval(min(300, Double(1 << min(job.attempts, 8))))
        }
        guard !Task.isCancelled, revisions[accountID] == generation else { return }
        try await repository.saveIncomingFileJob(job)
      }
    } catch {
      if !Task.isCancelled, revisions[accountID] == generation { archiveFailures[accountID] = "Не удалось обработать архив файлов WhatsApp." }
    }
  }
}

import Foundation
import CryptoKit
import Postbox

/// Metadata for a captured ZIP awaiting native pointer installation. The ZIP
/// and canonical resources remain immutable in their original storage policy.
struct TelegramPendingUploadArchiveCapture: Sendable {
    let expectedRevision: UUID
    let candidate: TelegramPendingUploadDraft
}

private let archiveCaptureMarker = Data("Makosh.PendingUpload.ArchiveCapture.v1\n".utf8)
private let archiveCaptureHeaderBytes = 36 + 32

nonisolated func telegramPendingUploadArchiveCaptureKey(accountID: Int64, chatID: Int64) -> ValueBoxKey {
    let namespace = Data("Makosh.PendingUpload.ArchiveCapture.Preference.v1\0".utf8)
    let key = ValueBoxKey(length: namespace.count + 16)
    key.setData(0, value: namespace)
    key.setInt64(namespace.count, value: accountID)
    key.setInt64(namespace.count + 8, value: chatID)
    return key
}

private func archiveCaptureEncoding(_ draft: TelegramPendingUploadDraft) -> Data? {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(draft), data.count <= 512 * 1024 else { return nil }
    return data
}

private func archiveCaptureMatches(_ capture: TelegramPendingUploadArchiveCapture,
                                   current: TelegramPendingUploadDraft, accountID: Int64, chatID: Int64) -> Bool {
    let candidate = capture.candidate
    guard current.isValid, current.schemaVersion == 15, current.disposition == .prepared,
          current.accountID == accountID, current.chatID == chatID, current.revision == capture.expectedRevision,
          candidate.isValid, candidate.schemaVersion == 16, candidate.disposition == .prepared,
          candidate.accountID == accountID, candidate.chatID == chatID,
          candidate.revision != capture.expectedRevision, let archive = candidate.archive,
          let expected = try? TelegramPendingUploadDraft(id: current.id, revision: candidate.revision,
            accountID: accountID, chatID: chatID, title: current.title, captionInput: current.captionInput,
            originalDraft: current.originalDraft, replyTarget: current.replyTarget, items: current.items,
            isGrouped: false, presentation: .archive, captionRules: current.captionRules, archive: archive),
          let expectedBytes = archiveCaptureEncoding(expected), let candidateBytes = archiveCaptureEncoding(candidate) else { return false }
    return expectedBytes == candidateBytes
}

nonisolated func telegramPendingUploadArchiveCaptureRead(transaction: Transaction, accountID: Int64, chatID: Int64)
    -> Result<TelegramPendingUploadArchiveCapture?, TelegramPendingUploadPersistenceError> {
    guard let entry = transaction.getPreferencesEntry(key: telegramPendingUploadArchiveCaptureKey(accountID: accountID, chatID: chatID)) else {
        return .success(nil)
    }
    let data = entry.data, offset = archiveCaptureMarker.count
    guard data.count > offset + archiveCaptureHeaderBytes, data.count <= offset + archiveCaptureHeaderBytes + 512 * 1024,
          data.starts(with: archiveCaptureMarker),
          let revisionText = String(data: data.subdata(in: offset..<(offset + 36)), encoding: .utf8),
          let revision = UUID(uuidString: revisionText), revision != TelegramPendingUploadDraft.zeroUUID,
          let candidate = try? JSONDecoder().decode(TelegramPendingUploadDraft.self,
              from: data.dropFirst(offset + archiveCaptureHeaderBytes)) else { return .failure(.incompatibleData) }
    let capture = TelegramPendingUploadArchiveCapture(expectedRevision: revision, candidate: candidate)
    switch telegramPendingUploadRead(transaction: transaction, accountID: accountID, chatID: chatID) {
    case let .failure(error): return .failure(error)
    case let .success(current):
        guard let current, archiveCaptureMatches(capture, current: current, accountID: accountID, chatID: chatID),
              let encoded = archiveCaptureEncoding(current),
              data.subdata(in: (offset + 36)..<(offset + archiveCaptureHeaderBytes)) == Data(SHA256.hash(data: encoded)) else {
            return .failure(.conflict)
        }
        return .success(capture)
    }
}

nonisolated func telegramPendingUploadArchiveCaptureWrite(transaction: Transaction, accountID: Int64,
    draft: TelegramPendingUploadDraft, expectedRevision: UUID, admission: TelegramPendingUploadArchiveAdmission)
    -> Result<Void, TelegramPendingUploadPersistenceError> {
    admission.withAdmission(accountID: accountID, chatID: draft.chatID, preparationID: draft.id, expectedRevision: expectedRevision) {
        switch telegramPendingUploadRead(transaction: transaction, accountID: accountID, chatID: draft.chatID) {
        case let .failure(error): return .failure(error)
        case let .success(current):
            let capture = TelegramPendingUploadArchiveCapture(expectedRevision: expectedRevision, candidate: draft)
            guard let current, archiveCaptureMatches(capture, current: current, accountID: accountID, chatID: draft.chatID),
                  let base = archiveCaptureEncoding(current), let candidate = archiveCaptureEncoding(draft) else { return .failure(.conflict) }
            let data = archiveCaptureMarker + Data(expectedRevision.uuidString.utf8) + Data(SHA256.hash(data: base)) + candidate
            let key = telegramPendingUploadArchiveCaptureKey(accountID: accountID, chatID: draft.chatID)
            if let existing = transaction.getPreferencesEntry(key: key) {
                return existing.data == data ? .success(()) : .failure(.conflict)
            }
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: data))
            return .success(())
        }
    }
}

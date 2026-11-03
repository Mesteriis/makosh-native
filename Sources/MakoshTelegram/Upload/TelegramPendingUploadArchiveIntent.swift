import Foundation
import CryptoKit
import MakoshCore
import Postbox

/// Reserves the exact ZIP/object/candidate identities before the first capture.
/// The native envelope binds it to the complete ordinary predecessor bytes.
struct TelegramPendingUploadArchiveIntent: Codable, Sendable {
    let preparationID: UUID
    let expectedRevision: UUID
    let archiveID: UUID
    let recordID: UUID
    let candidateRevision: UUID
    let byteCount: Int64
    let plaintextSHA256: String
    let members: [TelegramPendingUploadArchive.Member]

    func isValid(for current: TelegramPendingUploadDraft) -> Bool {
        let ids = [archiveID, recordID, candidateRevision]
        let resources = current.items.flatMap { [$0.file] + ($0.originalFile.map { [$0] } ?? []) + ($0.videoCover.map { [$0.file] } ?? []) }
        return current.isValid && current.canCaptureArchive && current.disposition == .prepared &&
            current.captionRules != .legacy && preparationID == current.id && expectedRevision == current.revision &&
            (2...TelegramUploadArchiveLimits.members).contains(current.items.count) &&
            Set(ids).count == ids.count && ids.allSatisfy { $0 != TelegramPendingUploadDraft.zeroUUID && $0 != current.id && $0 != current.revision &&
                !current.items.map(\.id).contains($0) && !resources.map(\.id).contains($0) } &&
            byteCount >= 22 && byteCount < Int64(UInt32.max) && plaintextSHA256.utf8.count == 64 &&
            plaintextSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            members.map(\.itemID) == current.items.map(\.id) &&
            (try? TelegramUploadArchiveLimits.validateEntryNames(members.map(\.entryName))) != nil
    }

    func candidate(current: TelegramPendingUploadDraft, record: ArchiveFileRecord) throws -> TelegramPendingUploadDraft {
        guard isValid(for: current), record.id == recordID, record.plaintextByteCount == byteCount,
              record.plaintextSHA256 == plaintextSHA256 else { throw TelegramPendingUploadPersistenceError.conflict }
        return try TelegramPendingUploadDraft(id: current.id, revision: candidateRevision, accountID: current.accountID,
            chatID: current.chatID, threadID: current.threadID, title: current.title, captionInput: current.captionInput,
            originalDraft: current.originalDraft, replyTarget: current.replyTarget, items: current.items,
            isGrouped: false, presentation: .archive, captionRules: current.captionRules, mediaRules: current.mediaRules,
            archive: .init(id: archiveID, file: record, members: members), captionPolicy: current.captionPolicy)
    }
}

private let intentMarker = Data("Makosh.PendingUpload.ArchiveIntent.v1\n".utf8)

nonisolated func telegramPendingUploadArchiveIntentKey(accountID: Int64, chatID: Int64) -> ValueBoxKey {
    let namespace = Data("Makosh.PendingUpload.ArchiveIntent.Preference.v1\0".utf8)
    let key = ValueBoxKey(length: namespace.count + 16)
    key.setData(0, value: namespace); key.setInt64(namespace.count, value: accountID); key.setInt64(namespace.count + 8, value: chatID)
    return key
}

private func intentEncoding<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard data.count <= 512 * 1024 else { throw TelegramPendingUploadPersistenceError.incompatibleData }
    return data
}

nonisolated func telegramPendingUploadArchiveIntentRead(transaction: Transaction, accountID: Int64, chatID: Int64)
    -> Result<TelegramPendingUploadArchiveIntent?, TelegramPendingUploadPersistenceError> {
    guard let entry = transaction.getPreferencesEntry(key: telegramPendingUploadArchiveIntentKey(accountID: accountID, chatID: chatID)) else { return .success(nil) }
    let data = entry.data, offset = intentMarker.count
    guard data.count > offset + 32, data.count <= offset + 32 + 512 * 1024, data.starts(with: intentMarker),
          let intent = try? JSONDecoder().decode(TelegramPendingUploadArchiveIntent.self, from: data.dropFirst(offset + 32)) else { return .failure(.incompatibleData) }
    switch telegramPendingUploadRead(transaction: transaction, accountID: accountID, chatID: chatID) {
    case let .failure(error): return .failure(error)
    case let .success(current):
        guard let current, intent.isValid(for: current), let encoded = try? intentEncoding(current),
              data.subdata(in: offset..<(offset + 32)) == Data(SHA256.hash(data: encoded)) else { return .failure(.conflict) }
        return .success(intent)
    }
}

nonisolated func telegramPendingUploadArchiveIntentWrite(transaction: Transaction, accountID: Int64, chatID: Int64,
    intent: TelegramPendingUploadArchiveIntent, admission: TelegramPendingUploadArchiveAdmission)
    -> Result<Void, TelegramPendingUploadPersistenceError> {
    admission.withAdmission(accountID: accountID, chatID: chatID, preparationID: intent.preparationID, expectedRevision: intent.expectedRevision) {
        switch telegramPendingUploadRead(transaction: transaction, accountID: accountID, chatID: chatID) {
        case let .failure(error): return .failure(error)
        case let .success(current):
            guard let current, intent.isValid(for: current), let base = try? intentEncoding(current),
                  let encoded = try? intentEncoding(intent) else { return .failure(.conflict) }
            let data = intentMarker + Data(SHA256.hash(data: base)) + encoded
            let key = telegramPendingUploadArchiveIntentKey(accountID: accountID, chatID: chatID)
            if let existing = transaction.getPreferencesEntry(key: key) { return existing.data == data ? .success(()) : .failure(.conflict) }
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: data))
            return .success(())
        }
    }
}

nonisolated func telegramPendingUploadArchiveIntentMatches(transaction: Transaction, current: TelegramPendingUploadDraft,
    candidate: TelegramPendingUploadDraft, requiredRecordID: UUID?) -> Bool {
    switch telegramPendingUploadArchiveIntentRead(transaction: transaction, accountID: current.accountID, chatID: current.chatID) {
    case .failure: return false
    case .success(nil): return requiredRecordID == nil // Existing explicitly supplied captures remain compatible.
    case let .success(intent?):
        guard requiredRecordID == nil || requiredRecordID == intent.recordID,
              let record = candidate.archive?.file, let expected = try? intent.candidate(current: current, record: record),
              let expectedBytes = try? intentEncoding(expected), let actualBytes = try? intentEncoding(candidate) else { return false }
        return expectedBytes == actualBytes
    }
}
